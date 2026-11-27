# Pin the maintainer's RSA SubjectPublicKeyInfo PEM in a separately approved change.
# An empty pin disables release discovery and installation.
$script:UpdaterReleasePublicKey = ''

# A rotation bridge carries its previous client pin here for release jobs only.
$script:UpdaterBridgeSigningPublicKey = ''
