<#
.SYNOPSIS
    Creates a self-signed client identity certificate in the CurrentUser\My store.

.DESCRIPTION
    Writes the thumbprint of the new certificate on the first line of standard output and its
    Base64-encoded DER on the second.
#>

param(
    [Parameter(Mandatory)]
    [string]$SubjectCn,

    [Parameter(Mandatory)]
    [ValidateSet('Rsa', 'EcdsaP256')]
    [string]$Algorithm
)

$ErrorActionPreference = 'Stop'

# `2.5.29.37` is the Extended Key Usage extension and `1.3.6.1.5.5.7.3.2` within it is clientAuth.
$parameters = @{
    Type              = 'Custom'
    Subject           = "CN=$SubjectCn"
    CertStoreLocation = 'Cert:\CurrentUser\My'
    Provider          = 'Microsoft Software Key Storage Provider'
    KeyExportPolicy   = 'NonExportable'
    KeyUsage          = 'DigitalSignature'
    TextExtension     = @('2.5.29.37={text}1.3.6.1.5.5.7.3.2')
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
