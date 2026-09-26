package poller_test

import (
	"context"
	"sync"
	"time"

	"github.com/yaanfpv/cgm-relay/internal/cgm"
)

// sourceResponse is one scripted return value for fakeSource.Fetch.
type sourceResponse struct {
	current *cgm.Reading
	history []cgm.Reading
	err     error
}

// fakeSource is a cgm.Source whose response to each call is decided by
// respond, given the zero-based call number.
type fakeSource struct {
	mu      sync.Mutex
	calls   int
	respond func(call int) sourceResponse
}

// scriptedSource returns a fakeSource that replays script in order, one
// entry per call, repeating its last entry for any call beyond the end of
// the script.
func scriptedSource(script []sourceResponse) *fakeSource {
	return &fakeSource{respond: func(call int) sourceResponse {
		if call < len(script) {
			return script[call]
		}
		return script[len(script)-1]
	}}
}

func (f *fakeSource) Fetch(_ context.Context) (*cgm.Reading, []cgm.Reading, error) {
	f.mu.Lock()
	call := f.calls
	f.calls++
	f.mu.Unlock()
	resp := f.respond(call)
	return resp.current, resp.history, resp.err
}

// blockingSource is a cgm.Source whose Fetch signals started, then blocks
// until ctx is done, returning ctx's own error -- it stands in for a real
// network call that respects cancellation, for tests that cancel mid-fetch.
type blockingSource struct {
	started chan struct{}
}

func newBlockingSource() *blockingSource {
	return &blockingSource{started: make(chan struct{})}
}

func (b *blockingSource) Fetch(ctx context.Context) (*cgm.Reading, []cgm.Reading, error) {
	close(b.started)
	<-ctx.Done()
	return nil, nil, ctx.Err()
}

// fakeStore is a poller.Store that records every call instead of
// persisting anything. currentErrs and historyErrs, if set, are consumed
// one per call in order; once exhausted, every further call succeeds.
type fakeStore struct {
	mu          sync.Mutex
	current     []cgm.Reading
	history     []cgm.Reading
	pruneCalls  []time.Time
	currentErrs []error
	historyErrs []error
	pruneErr    error
}

func (f *fakeStore) InsertCurrent(_ context.Context, r cgm.Reading) (bool, error) {
	f.mu.Lock()
	defer f.mu.Unlock()
	if err := shiftErr(&f.currentErrs); err != nil {
		return false, err
	}
	f.current = append(f.current, r)
	return true, nil
}

func (f *fakeStore) InsertHistory(_ context.Context, r cgm.Reading) (bool, error) {
	f.mu.Lock()
	defer f.mu.Unlock()
	if err := shiftErr(&f.historyErrs); err != nil {
		return false, err
	}
	f.history = append(f.history, r)
	return true, nil
}

func (f *fakeStore) Prune(_ context.Context, now time.Time, _ time.Duration) (int64, error) {
	f.mu.Lock()
	defer f.mu.Unlock()
	f.pruneCalls = append(f.pruneCalls, now)
	if f.pruneErr != nil {
		return 0, f.pruneErr
	}
	return 0, nil
}

func (f *fakeStore) currentTimes() []time.Time {
	f.mu.Lock()
	defer f.mu.Unlock()
	out := make([]time.Time, len(f.current))
	for i, r := range f.current {
		out[i] = r.Time
	}
	return out
}

func (f *fakeStore) historyTimes() []time.Time {
	f.mu.Lock()
	defer f.mu.Unlock()
	out := make([]time.Time, len(f.history))
	for i, r := range f.history {
		out[i] = r.Time
	}
	return out
}

func (f *fakeStore) pruneCallCount() int {
	f.mu.Lock()
	defer f.mu.Unlock()
	return len(f.pruneCalls)
}

// shiftErr pops and returns the first error in *errs, if any are left,
// leaving the rest for the next call; it returns nil once the list is
// empty, so a fakeStore with no scripted errors always succeeds.
func shiftErr(errs *[]error) error {
	if len(*errs) == 0 {
		return nil
	}
	err := (*errs)[0]
	*errs = (*errs)[1:]
	return err
}
