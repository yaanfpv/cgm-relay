//go:build !darwin

package tailnode

// excludeFromBackup does nothing off macOS, where Time Machine is.
func excludeFromBackup(string) error { return nil }
