# ==============================================================================
# File Name: ota_crypto.gd
# Path: res://scripts/ota/ota_crypto.gd
#
# Description:
#   Hashing and signature checking for OTA documents. Signatures are RSA PKCS#1 v1.5 over SHA-256
#   (what `openssl dgst -sha256 -sign key.pem` produces), checked against the public key that CI
#   writes into every build as res://ota_trust.pem. Every function fails closed: bad input -> false / "".
# ==============================================================================
class_name OtaCrypto
extends RefCounted


static func sha256_bytes(data: PackedByteArray) -> String:
	var ctx := HashingContext.new()
	ctx.start(HashingContext.HASH_SHA256)
	ctx.update(data)
	return ctx.finish().hex_encode()


## Streaming SHA-256 of a (possibly large) file; "" when it cannot be read.
static func sha256_file(path: String) -> String:
	var f := FileAccess.open(path, FileAccess.READ)
	if f == null:
		return ""
	var ctx := HashingContext.new()
	ctx.start(HashingContext.HASH_SHA256)
	while not f.eof_reached():
		var chunk: PackedByteArray = f.get_buffer(1 << 20)
		if chunk.is_empty():
			break
		ctx.update(chunk)
	return ctx.finish().hex_encode()


## True only if `sig_b64` is a valid signature of exactly `data` under the PEM public key.
static func verify(data: PackedByteArray, sig_b64: String, public_pem: String) -> bool:
	if data.is_empty() or public_pem.strip_edges() == "":
		return false
	var key := CryptoKey.new()
	if key.load_from_string(public_pem, true) != OK:
		return false
	var cleaned: String = sig_b64.strip_edges().replace("\n", "").replace("\r", "").replace(" ", "")
	if cleaned == "":
		return false
	var sig: PackedByteArray = Marshalls.base64_to_raw(cleaned)
	if sig.is_empty():
		return false
	var ctx := HashingContext.new()
	ctx.start(HashingContext.HASH_SHA256)
	ctx.update(data)
	var digest: PackedByteArray = ctx.finish()
	return Crypto.new().verify(HashingContext.HASH_SHA256, digest, sig, key)
