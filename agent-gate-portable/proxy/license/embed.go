package license

import (
	_ "embed"
)

//go:embed public.pem
var PublicKeyPEM []byte
