package tailnode

import (
	"context"
	"strings"
	"sync"
	"time"
)

// The cadence and limits of the public address's health. A healthy address is
// tested every healthyInterval; after a failure the wait doubles from
// backoffFirst up to backoffMax, so a failing address is noticed quickly and
// a dead one is not hammered.
const (
	healthyInterval = 2 * time.Minute
	backoffFirst    = 30 * time.Second
	backoffMax      = 5 * time.Minute

	// A run of failuresToNotAnswer failures that spans at least
	// notAnsweringSpan is an address that stopped answering; fewer, or a
	// shorter run, is a blip.
	failuresToNotAnswer = 3
	notAnsweringSpan    = 4 * time.Minute

	// The listener is reopened reopensBeforeRestart times before the node is
	// restarted, and restarts are limited so a failure that a restart cannot
	// fix does not become a restart loop.
	reopensBeforeRestart = 2
	restartGap           = 5 * time.Minute
	restartsPerHour      = 3
)

// MaxCount bounds each count the monitor keeps.
const MaxCount = 9999

// Count names of the two Tailscale log lines that are counted.
const (
	countIngressDenied = "ingress_denied"
	countHandshake     = "handshake"
)

// Repairer reopens the public listener and restarts the node. A restart keeps
// the node's state folder, so its key and sign-in survive.
type Repairer interface {
	ReopenListener(ctx context.Context) error
	RestartNode(ctx context.Context) error
}

// ProbeFunc makes one test of the public address host and classifies it.
type ProbeFunc func(ctx context.Context, host string) ProbeClass

// NodeCheck reads whether the node itself is online and healthy. It returns
// ProbeOK, or the node-side class that says why not.
type NodeCheck func(ctx context.Context) ProbeClass

// MonitorOptions configure a Monitor.
type MonitorOptions struct {
	Now    func() time.Time
	Probe  ProbeFunc
	Node   NodeCheck
	Repair Repairer
}

// Monitor turns public tests into the facts State reports (when the address
// last answered, since when it has not, whether the Mac is the problem) and
// into repairs. Step and TryAgain run one test and are called from one
// goroutine at a time; the other methods are safe from any goroutine.
type Monitor struct {
	opts MonitorOptions

	mu       sync.Mutex
	counts   map[string]int
	lastOK   time.Time
	streak   int // tests in a row that were neither a success nor neutral
	runLen   int // route failures in the current run
	runStart time.Time
	na       time.Time // zero while the address answers
	waiting  bool
	rung     int // reopens done since the last restart or success
	restarts []time.Time
	nextAt   time.Time
}

// NewMonitor returns a Monitor with no test made yet.
func NewMonitor(opts MonitorOptions) *Monitor {
	if opts.Now == nil {
		opts.Now = time.Now
	}
	return &Monitor{opts: opts, counts: map[string]int{}}
}

// Step makes one test of host and repairs what the result calls for. It
// returns how long to wait before the next test.
func (m *Monitor) Step(ctx context.Context, host string) time.Duration {
	return m.test(ctx, host)
}

// TryAgain is Step for a person who asked: the caller makes the test at once
// instead of waiting for its time, and a failed one takes the next repair step
// under the same restart limits.
func (m *Monitor) TryAgain(ctx context.Context, host string) time.Duration {
	return m.test(ctx, host)
}

func (m *Monitor) test(ctx context.Context, host string) time.Duration {
	// The public test always runs, and an answer is Ready whatever the node
	// reports. Only a failed test is explained by the node, and only by a node
	// that is offline or cannot be read: that is waiting, not a route fault.
	// Health warnings are counted and change nothing, since one that never
	// clears must not hide a real drop or stop its repair.
	class := m.opts.Probe(ctx, host)
	health := false
	if class != ProbeOK && class != ProbeTailnetAddress && m.opts.Node != nil {
		switch node := m.opts.Node(ctx); node {
		case ProbeNodeOffline, ProbeStatusRead:
			class = node
		case ProbeNodeHealth:
			health = true
		}
	}
	if ctx.Err() != nil {
		// The test was cut off by the node closing, which says nothing about
		// the address.
		return m.Due()
	}
	m.mu.Lock()
	if health && m.counts[ProbeNodeHealth.String()] < MaxCount {
		m.counts[ProbeNodeHealth.String()]++
	}
	next, repair := m.record(class, m.opts.Now())
	m.mu.Unlock()
	if m.opts.Repair != nil {
		switch repair {
		case repairReopen:
			_ = m.opts.Repair.ReopenListener(ctx)
		case repairRestart:
			_ = m.opts.Repair.RestartNode(ctx)
		}
	}
	return next
}

type repairKind int

const (
	repairNone repairKind = iota
	repairReopen
	repairRestart
)

// record folds one test result into the state, with m.mu held, and returns
// the wait before the next test and the repair it calls for.
func (m *Monitor) record(class ProbeClass, now time.Time) (time.Duration, repairKind) {
	if class != ProbeOK {
		if k := class.String(); m.counts[k] < MaxCount {
			m.counts[k]++
		}
	}
	repair := repairNone
	switch {
	case class == ProbeOK:
		m.lastOK, m.streak, m.runLen, m.rung = now, 0, 0, 0
		m.na, m.waiting = time.Time{}, false
	case class == ProbeTailnetAddress:
		// A name that resolves inside the tailnet proves nothing about the
		// public route, so it neither renews, lifts nor breaks anything.
	case class.MacSide() || class.NodeSide():
		m.streak++
		m.waiting = true
		m.runLen, m.na = 0, time.Time{}
	default:
		m.streak++
		m.waiting = false
		if m.runLen == 0 {
			m.runStart = now
		}
		m.runLen++
		if m.na.IsZero() && m.runLen >= failuresToNotAnswer && now.Sub(m.runStart) >= notAnsweringSpan {
			m.na = m.runStart
		}
		if !m.na.IsZero() {
			repair = m.nextRepair(now)
		}
	}
	d := healthyInterval
	if m.streak > 0 {
		d = backoffMax
		if m.streak <= 6 {
			d = min(backoffFirst<<(m.streak-1), backoffMax)
		}
	}
	m.nextAt = now.Add(d)
	return d, repair
}

// nextRepair picks the next step of the ladder, with m.mu held: reopen the
// listener twice, then restart the node if the restart limits allow it. A
// restart starts the ladder again from a reopen.
func (m *Monitor) nextRepair(now time.Time) repairKind {
	if m.rung < reopensBeforeRestart {
		m.rung++
		return repairReopen
	}
	recent := m.restarts[:0]
	for _, t := range m.restarts {
		if now.Sub(t) < time.Hour {
			recent = append(recent, t)
		}
	}
	m.restarts = recent
	if n := len(recent); n >= restartsPerHour || (n > 0 && now.Sub(recent[n-1]) < restartGap) {
		return repairNone
	}
	m.restarts = append(m.restarts, now)
	m.rung = 0
	return repairRestart
}

// Apply returns o with the monitor's facts filled in.
func (m *Monitor) Apply(o Observation) Observation {
	m.mu.Lock()
	defer m.mu.Unlock()
	o.Now = m.opts.Now()
	o.CheckedAt = m.lastOK
	o.NotAnsweringSince = m.na
	o.WaitingForInternet = m.waiting
	o.Counts = m.countsLocked()
	return o
}

// Answered reports that the address has answered a test.
func (m *Monitor) Answered() bool {
	m.mu.Lock()
	defer m.mu.Unlock()
	return !m.lastOK.IsZero()
}

// MarkAnswered records that the address answered, for the first request the
// node makes to it before the monitor's own tests begin.
func (m *Monitor) MarkAnswered() {
	m.mu.Lock()
	defer m.mu.Unlock()
	m.record(ProbeOK, m.opts.Now())
}

// Due is how long until the next test is due, zero if it is overdue.
func (m *Monitor) Due() time.Duration {
	m.mu.Lock()
	defer m.mu.Unlock()
	if m.nextAt.IsZero() {
		return healthyInterval
	}
	return max(m.nextAt.Sub(m.opts.Now()), 0)
}

// Counts returns a copy of the counts: each failure class under its name, and
// the Tailscale log lines under "ingress_denied" and "handshake".
func (m *Monitor) Counts() map[string]int {
	m.mu.Lock()
	defer m.mu.Unlock()
	out := m.countsLocked()
	if out == nil {
		out = map[string]int{}
	}
	return out
}

func (m *Monitor) countsLocked() map[string]int {
	if len(m.counts) == 0 {
		return nil
	}
	out := make(map[string]int, len(m.counts))
	for k, v := range m.counts {
		out[k] = v
	}
	return out
}

// ObserveLog counts a Tailscale log line when it is one of the two kinds
// kept. Nothing of the line is kept, since it can name an address or a peer.
func (m *Monitor) ObserveLog(line string) {
	var key string
	switch {
	case strings.Contains(line, "ingress: denied"):
		key = countIngressDenied
	case strings.Contains(line, "Handshake did not complete"):
		key = countHandshake
	default:
		return
	}
	m.mu.Lock()
	defer m.mu.Unlock()
	if m.counts[key] < MaxCount {
		m.counts[key]++
	}
}
