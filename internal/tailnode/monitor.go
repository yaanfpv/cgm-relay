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

	// While the address is publishing or not reachable, a Try Again
	// re-registers Funnel at most once in pressGap and pressesPerHour times in
	// an hour.
	pressGap       = 5 * time.Minute
	pressesPerHour = 3

	// minReregisterGap is the least time between two re-registrations of Funnel.
	minReregisterGap = 30 * time.Second
)

// MaxCount bounds each count the monitor keeps.
const MaxCount = 9999

// Count names of the two Tailscale log lines that are counted.
const (
	countIngressDenied = "ingress_denied"
	countHandshake     = "handshake"
	countReconnect     = "control_reconnect"
)

// The node's own log lines for a control map session that ended or came back.
// The first is what a session's end is logged as once its label is filled in.
const (
	lineMapEnded = "PollNetMap: EOF"
	lineDialPlan = "netmap: got new dial plan from control"
)

// Repairer reopens the public listener and restarts the node. A restart keeps
// the node's state folder, so its key and sign-in survive.
type Repairer interface {
	ReopenListener(ctx context.Context) error
	RestartNode(ctx context.Context) error
	// ReregisterFunnel turns Funnel's registration off and on again in the
	// node's serve config, keeping the listener, so the node sends control
	// its Funnel state afresh.
	ReregisterFunnel(ctx context.Context) error
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

	mu        sync.Mutex
	counts    map[string]int
	lastOK    time.Time
	streak    int // tests in a row that were neither a success nor neutral
	runLen    int // route failures in the current run
	runStart  time.Time
	na        time.Time // zero while the address answers
	waiting   bool
	rung      int // reopens done since the last restart or success
	restarts  []time.Time
	nextAt    time.Time
	presses   []time.Time // the re-registrations Try Again made, apart from the restart ledger
	lastPress time.Time
	// afterRestart is set by a restart and cleared by the first re-registration
	// that follows it, which a failed test makes before the ladder may restart
	// again.
	afterRestart bool
	// noStep is set while the test that follows a re-registration is made:
	// the registration has had no time to show, so a failure of that test is
	// counted and judged but takes no step of the ladder.
	noStep bool

	// pendingReconnect is set by a reconnect line and taken by AfterReconnect.
	// reconnected wakes the serving session, and holds one wake so a line is
	// never lost between the log and the session.
	pendingReconnect bool
	reconnected      chan struct{}
	lastRereg        time.Time
}

// NewMonitor returns a Monitor with no test made yet.
func NewMonitor(opts MonitorOptions) *Monitor {
	if opts.Now == nil {
		opts.Now = time.Now
	}
	return &Monitor{opts: opts, counts: map[string]int{}, reconnected: make(chan struct{}, 1)}
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
	next, _, _ := m.testOnce(ctx, host)
	return next
}

// testOnce is test, and also reports the class the test found and whether it
// re-registered Funnel as the first failure of a run.
func (m *Monitor) testOnce(ctx context.Context, host string) (time.Duration, ProbeClass, bool) {
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
		return m.Due(), ProbeOK, false
	}
	m.mu.Lock()
	if health && m.counts[ProbeNodeHealth.String()] < MaxCount {
		m.counts[ProbeNodeHealth.String()]++
	}
	now := m.opts.Now()
	restarted := m.afterRestart
	next, repair := m.record(class, now)
	// The first route failure of a run has Funnel's registration renewed
	// before the ladder does anything, since control may have lost it with
	// no line in the log to say so, and so does the first failed test on a node
	// that was just restarted. A reconnect just handled, or a press's
	// re-registration just made, counts as one.
	rereg := class.RouteFailure() && (m.runLen == 1 || restarted) && m.firstFailureDue(now)
	m.mu.Unlock()
	if m.opts.Repair != nil {
		if rereg {
			_ = m.opts.Repair.ReregisterFunnel(ctx)
		}
		switch repair {
		case repairReopen:
			_ = m.opts.Repair.ReopenListener(ctx)
		case repairRestart:
			_ = m.opts.Repair.RestartNode(ctx)
		}
	}
	return next, class, rereg
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
		if !m.na.IsZero() && !m.noStep {
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
	if m.afterRestart || !m.restartAllowed(now) {
		return repairNone
	}
	m.restarts = append(m.restarts, now)
	m.afterRestart = true
	m.rung = 0
	return repairRestart
}

// restartAllowed reports whether the limits allow a restart at now, with m.mu
// held, and forgets the restarts that are over an hour old.
func (m *Monitor) restartAllowed(now time.Time) bool {
	recent := m.restarts[:0]
	for _, t := range m.restarts {
		if now.Sub(t) < time.Hour {
			recent = append(recent, t)
		}
	}
	m.restarts = recent
	n := len(recent)
	return n < restartsPerHour && (n == 0 || now.Sub(recent[n-1]) >= restartGap)
}

// RecordRestart enters a restart the limits did not decide, so that later
// repairs see it, and has the first failed test after it re-register Funnel.
func (m *Monitor) RecordRestart() {
	m.mu.Lock()
	defer m.mu.Unlock()
	m.restarts = append(m.restarts, m.opts.Now())
	m.afterRestart = true
}

// AllowPress reports whether a Try Again may re-register Funnel now, and if so
// enters it in the ledger of presses: at most one in pressGap and
// pressesPerHour in an hour. The ledger is separate from the restarts'. Only a
// press made while the address is publishing or not reachable asks it; on a
// serving node a press tests at once and a failure takes the first-failure
// re-registration and the ladder.
func (m *Monitor) AllowPress() bool {
	m.mu.Lock()
	defer m.mu.Unlock()
	now := m.opts.Now()
	recent := m.presses[:0]
	for _, t := range m.presses {
		if now.Sub(t) < time.Hour {
			recent = append(recent, t)
		}
	}
	m.presses = recent
	n := len(recent)
	if n >= pressesPerHour || (n > 0 && now.Sub(recent[n-1]) < pressGap) {
		return false
	}
	m.presses = append(m.presses, now)
	m.lastPress = now
	return true
}

// NoteFailure counts a failed test that does not feed the run of failures,
// as those made before the address has first answered do.
func (m *Monitor) NoteFailure(class ProbeClass) {
	if class == ProbeOK {
		return
	}
	m.mu.Lock()
	defer m.mu.Unlock()
	if k := class.String(); m.counts[k] < MaxCount {
		m.counts[k]++
	}
}

// reregisterDue reports, with m.mu held, whether Funnel may be re-registered
// at now, and if so enters it as done.
func (m *Monitor) reregisterDue(now time.Time) bool {
	if !m.lastRereg.IsZero() && now.Sub(m.lastRereg) < minReregisterGap {
		return false
	}
	m.lastRereg = now
	return true
}

// firstFailureDue reports, with m.mu held, whether a failed test may
// re-register Funnel at now, and if so enters it as done. A re-registration
// within minReregisterGap of the last, or of a press's, is the one that
// failed test would make, so it is not made twice.
func (m *Monitor) firstFailureDue(now time.Time) bool {
	if !m.lastPress.IsZero() && now.Sub(m.lastPress) < minReregisterGap {
		m.afterRestart = false
		return false
	}
	if !m.reregisterDue(now) {
		return false
	}
	m.afterRestart = false
	return true
}

// AfterReconnect acts on the reconnect lines seen since it last ran: the
// address is tested at once like any other test, and only a failed one has
// Funnel's registration turned off and on, followed by another test at once,
// which takes no ladder step of its own.
// It reports whether it tested, and how long to wait before the next test. The
// lines are one reconnect however many there are. A failed test within
// minReregisterGap of the last re-registration, or of a press's, is not
// followed by another: the first failed test and the repair ladder back it up.
func (m *Monitor) AfterReconnect(ctx context.Context, host string) (time.Duration, bool) {
	m.mu.Lock()
	pending := m.pendingReconnect
	m.pendingReconnect = false
	m.mu.Unlock()
	if !pending {
		return m.Due(), false
	}
	next, class, toggled := m.testOnce(ctx, host)
	if ctx.Err() != nil || !class.RouteFailure() {
		return next, true
	}
	if !toggled {
		m.mu.Lock()
		toggled = m.firstFailureDue(m.opts.Now())
		m.mu.Unlock()
		if toggled && m.opts.Repair != nil {
			_ = m.opts.Repair.ReregisterFunnel(ctx)
		}
	}
	if toggled {
		m.mu.Lock()
		m.noStep = true
		m.mu.Unlock()
		next = m.test(ctx, host)
		m.mu.Lock()
		m.noStep = false
		m.mu.Unlock()
	}
	return next, true
}

// ReconnectPending reports that a reconnect line has been seen and not acted
// on.
func (m *Monitor) ReconnectPending() bool {
	m.mu.Lock()
	defer m.mu.Unlock()
	return m.pendingReconnect
}

// Reconnects wakes whoever serves when a reconnect line is seen.
func (m *Monitor) Reconnects() <-chan struct{} { return m.reconnected }

// ForgetReconnects drops the reconnect lines seen so far, for a session that
// is only now beginning to serve: the lines a node logs while it starts are
// not a reconnect of a registration it has yet to make.
func (m *Monitor) ForgetReconnects() {
	m.mu.Lock()
	m.pendingReconnect = false
	m.mu.Unlock()
	select {
	case <-m.reconnected:
	default:
	}
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
	case strings.Contains(line, lineMapEnded), strings.Contains(line, lineDialPlan):
		key = countReconnect
	default:
		return
	}
	m.mu.Lock()
	defer m.mu.Unlock()
	if m.counts[key] < MaxCount {
		m.counts[key]++
	}
	if key == countReconnect {
		m.pendingReconnect = true
		select {
		case m.reconnected <- struct{}{}:
		default:
		}
	}
}
