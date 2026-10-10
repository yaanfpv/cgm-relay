package config

import (
	"crypto/tls"
	"crypto/x509"
	"encoding/pem"
	"errors"
	"fmt"
	"net"
	"net/netip"
	"strconv"
	"strings"
)

// ValidateLANListenAddrs checks that every entry of addrs is a "host:port"
// whose host is a private IPv4 address (10.0.0.0/8, 172.16.0.0/12 or
// 192.168.0.0/16) and whose port is a number from 0 to 65535. IPv6,
// wildcards, loopback, public and Tailscale (100.64.0.0/10) addresses and
// host names are all refused, so a LAN listener can only ever be reachable
// from the local network. The error names lan_listen_addrs and the offending
// entry.
func ValidateLANListenAddrs(addrs []string) error {
	for _, a := range addrs {
		host, port, err := net.SplitHostPort(a)
		if err != nil {
			return fmt.Errorf("lan_listen_addrs: %q is not a host:port pair", a)
		}
		ip, err := netip.ParseAddr(host)
		if err != nil || !ip.Is4() || !ip.IsPrivate() {
			return fmt.Errorf("lan_listen_addrs: %q is not a private IPv4 address (10.x.x.x, 172.16.x.x to 172.31.x.x or 192.168.x.x)", a)
		}
		if n, err := strconv.Atoi(port); err != nil || n < 0 || n > 65535 || strings.HasPrefix(port, "+") {
			return fmt.Errorf("lan_listen_addrs: %q has no valid port", a)
		}
	}
	return nil
}

// LANTLSConfig returns the TLS configuration the LAN listeners serve with,
// built from TLSCertPEM and TLSKeyPEM, or nil when LANListenAddrs is empty.
// It refuses, naming the offending field, a missing or malformed certificate
// or key and a pair that do not match. TLS 1.2 is the lowest version the
// configuration allows. Its errors never carry any part of the key.
func (c Config) LANTLSConfig() (*tls.Config, error) {
	if len(c.LANListenAddrs) == 0 {
		return nil, nil
	}
	if strings.TrimSpace(c.TLSCertPEM) == "" {
		return nil, errors.New("tls_cert_pem: required when lan_listen_addrs is set")
	}
	if strings.TrimSpace(c.TLSKeyPEM) == "" {
		return nil, errors.New("tls_key_pem: required when lan_listen_addrs is set")
	}
	cert, err := tls.X509KeyPair([]byte(c.TLSCertPEM), []byte(c.TLSKeyPEM))
	if err != nil {
		return nil, diagnoseKeyPair(c.TLSCertPEM, c.TLSKeyPEM)
	}
	return &tls.Config{
		Certificates: []tls.Certificate{cert},
		MinVersion:   tls.VersionTLS12,
	}, nil
}

// diagnoseKeyPair works out which field made tls.X509KeyPair fail and says
// so in words of its own: the parser's own errors are never passed on, so
// nothing derived from the key can reach a message.
func diagnoseKeyPair(certPEM, keyPEM string) error {
	if !hasParsableCertificate(certPEM) {
		return errors.New("tls_cert_pem: no valid PEM certificate found")
	}
	if !hasParsablePrivateKey(keyPEM) {
		return errors.New("tls_key_pem: no valid PEM private key found")
	}
	return errors.New("tls_cert_pem and tls_key_pem: the private key does not match the certificate")
}

// hasParsableCertificate reports whether certPEM's first CERTIFICATE block,
// the leaf, parses as an X.509 certificate.
func hasParsableCertificate(certPEM string) bool {
	rest := []byte(certPEM)
	for {
		var block *pem.Block
		block, rest = pem.Decode(rest)
		if block == nil {
			return false
		}
		if block.Type != "CERTIFICATE" {
			continue
		}
		_, err := x509.ParseCertificate(block.Bytes)
		return err == nil
	}
}

// hasParsablePrivateKey reports whether keyPEM's first private key block
// parses as a PKCS#8, PKCS#1 or SEC 1 key.
func hasParsablePrivateKey(keyPEM string) bool {
	rest := []byte(keyPEM)
	for {
		var block *pem.Block
		block, rest = pem.Decode(rest)
		if block == nil {
			return false
		}
		if !strings.HasSuffix(block.Type, "PRIVATE KEY") {
			continue
		}
		if _, err := x509.ParsePKCS8PrivateKey(block.Bytes); err == nil {
			return true
		}
		if _, err := x509.ParsePKCS1PrivateKey(block.Bytes); err == nil {
			return true
		}
		if _, err := x509.ParseECPrivateKey(block.Bytes); err == nil {
			return true
		}
		return false
	}
}
