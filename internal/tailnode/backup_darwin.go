//go:build darwin

package tailnode

import (
	"errors"

	"golang.org/x/sys/unix"
)

// backupExcludeAttr is the attribute Time Machine reads to skip an item. It
// stays with the folder, so a folder created again needs it again.
const backupExcludeAttr = "com.apple.metadata:com_apple_backup_excludeItem"

// backupExcludeValue is the binary property list holding the string
// "com.apple.backupd", the value the system's own tools write.
var backupExcludeValue = []byte{
	'b', 'p', 'l', 'i', 's', 't', '0', '0',
	0x5f, 0x10, 0x11,
	'c', 'o', 'm', '.', 'a', 'p', 'p', 'l', 'e', '.', 'b', 'a', 'c', 'k', 'u', 'p', 'd',
	0x08,
	0, 0, 0, 0, 0, 0, // unused, sort version
	1, 1, // offset size, object reference size
	0, 0, 0, 0, 0, 0, 0, 1, // object count
	0, 0, 0, 0, 0, 0, 0, 0, // top object
	0, 0, 0, 0, 0, 0, 0, 28, // offset table position
}

// excludeFromBackup marks dir as excluded from Time Machine backups. A volume
// that cannot hold the attribute has nothing to exclude it from.
func excludeFromBackup(dir string) error {
	err := unix.Setxattr(dir, backupExcludeAttr, backupExcludeValue, 0)
	if errors.Is(err, unix.ENOTSUP) {
		return nil
	}
	return err
}
