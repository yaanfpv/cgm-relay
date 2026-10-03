// Command edsig is the Ed25519 half of the release scripts: it derives the
// public key a signing key file implies and checks a signature against a
// public key, so a release can be verified with the public key alone.
//
// Usage:
//
//	edsig pub <key-file>
//	edsig verify <public-key-base64> <signature-base64> <file>
//
// A key file holds the base64 of the 32-byte Ed25519 seed. Exit status is 0
// for a valid signature, 1 for a signature that does not match, 2 for any
// input that cannot be read or decoded.
package main

import (
	"crypto/ed25519"
	"encoding/base64"
	"fmt"
	"os"
	"strings"
)

func main() {
	os.Exit(run(os.Args[1:]))
}

func run(args []string) int {
	switch {
	case len(args) == 2 && args[0] == "pub":
		return printPublicKey(args[1])
	case len(args) == 4 && args[0] == "verify":
		return verify(args[1], args[2], args[3])
	}
	fmt.Fprintln(os.Stderr, "usage: edsig pub <key-file> | edsig verify <public-key> <signature> <file>")
	return 2
}

func printPublicKey(keyFile string) int {
	raw, err := os.ReadFile(keyFile)
	if err != nil {
		fmt.Fprintf(os.Stderr, "edsig: %v\n", err)
		return 2
	}
	seed, err := base64.StdEncoding.DecodeString(strings.TrimSpace(string(raw)))
	if err != nil || len(seed) != ed25519.SeedSize {
		fmt.Fprintf(os.Stderr, "edsig: %s is not the base64 of a %d-byte Ed25519 seed\n", keyFile, ed25519.SeedSize)
		return 2
	}
	pub := ed25519.NewKeyFromSeed(seed).Public().(ed25519.PublicKey)
	fmt.Println(base64.StdEncoding.EncodeToString(pub))
	return 0
}

func verify(publicKey, signature, file string) int {
	pub, err := base64.StdEncoding.DecodeString(publicKey)
	if err != nil || len(pub) != ed25519.PublicKeySize {
		fmt.Fprintln(os.Stderr, "edsig: the public key is not the base64 of a 32-byte Ed25519 key")
		return 2
	}
	sig, err := base64.StdEncoding.DecodeString(signature)
	if err != nil || len(sig) != ed25519.SignatureSize {
		fmt.Fprintln(os.Stderr, "edsig: the signature is not the base64 of a 64-byte Ed25519 signature")
		return 2
	}
	data, err := os.ReadFile(file)
	if err != nil {
		fmt.Fprintf(os.Stderr, "edsig: %v\n", err)
		return 2
	}
	if !ed25519.Verify(pub, data, sig) {
		fmt.Fprintln(os.Stderr, "edsig: signature does not match")
		return 1
	}
	return 0
}
