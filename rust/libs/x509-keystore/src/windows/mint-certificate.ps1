<#
.SYNOPSIS
    Creates a self-signed client identity certificate in the LocalMachine\My store.

.DESCRIPTION
    Writes the thumbprint of the new certificate on the first line of standard output and its
    Base64-encoded DER on the second.
#>

param(
    [Parameter(Mandatory)]
    [string]$SubjectCn,

    [Parameter(Mandatory)]
    [ValidateSet('Rsa', 'EcdsaP256')]
    [string]$Algorithm,

    [Parameter(Mandatory)]
    [ValidateSet('SoftwareKsp', 'LegacyCsp')]
    [string]$KeyStorage
)

$ErrorActionPreference = 'Stop'

# `2.5.29.37` is the Extended Key Usage extension and `1.3.6.1.5.5.7.3.2` within it is clientAuth.
$parameters = @{
    Type              = 'Custom'
    Subject           = "CN=$SubjectCn"
    CertStoreLocation = 'Cert:\LocalMachine\My'
    KeyExportPolicy   = 'NonExportable'
    KeyUsage          = 'DigitalSignature'
    TextExtension     = @('2.5.29.37={text}1.3.6.1.5.5.7.3.2')
}

# The legacy CryptoAPI providers implement no RSA-PSS at all, which is what makes a key in one
# stand in for a key in a TPM: both refuse the padding a TLS 1.3 handshake is signed with.
#
# A CryptoAPI provider is addressed by its name and a provider type, and naming a key
# specification is what makes the cmdlet resolve the type: without one it asks for the provider
# type CryptoAPI has no definition for, and fails with NTE_PROV_TYPE_NOT_DEF.
switch ($KeyStorage) {
    'SoftwareKsp' { $parameters.Provider = 'Microsoft Software Key Storage Provider' }
    'LegacyCsp' {
        $parameters.Provider = 'Microsoft Enhanced RSA and AES Cryptographic Provider'
        $parameters.KeySpec = 'KeyExchange'
    }
}

switch ($Algorithm) {
    'Rsa' {
        $parameters.KeyAlgorithm = 'RSA'
        $parameters.KeyLength = 2048
    }
    'EcdsaP256' {
        $parameters.KeyAlgorithm = 'ECDSA_nistP256'
        # `CurveName` makes the certificate name its curve by OID instead of spelling out the curve
        # parameters, which is the encoding `x509-claims` reads the key algorithm from.
        $parameters.CurveExport = 'CurveName'
    }
}

$certificate = New-SelfSignedCertificate @parameters

# `[Console]::Out` bypasses PowerShell's formatter, which would wrap the long Base64 line.
[Console]::Out.WriteLine($certificate.Thumbprint)
[Console]::Out.WriteLine([Convert]::ToBase64String($certificate.RawData))
