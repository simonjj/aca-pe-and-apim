@description('APIM service name (the gateway host is <apimName>.azure-api.net).')
param apimName string

@description('Private VNet IP of the Internal-mode APIM service.')
param apimPrivateIp string

@description('Resource ID of the VNet to link.')
param vnetId string

@description('Tags.')
param tags object = {}

// In Internal VNet mode APIM has no public endpoints: every <apimName>.*.azure-api.net name
// resolves to the service's private VNet IP. Linking this zone to the VNet lets the App Gateway
// (and APIM itself) resolve the gateway host privately. Records cover the gateway plus the
// management/portal/developer/scm endpoints so APIM's own name resolution keeps working.
resource zone 'Microsoft.Network/privateDnsZones@2020-06-01' = {
  name: 'azure-api.net'
  location: 'global'
  tags: tags
}

var hostLabels = [
  apimName
  '${apimName}.management'
  '${apimName}.portal'
  '${apimName}.developer'
  '${apimName}.scm'
]

resource records 'Microsoft.Network/privateDnsZones/A@2020-06-01' = [for label in hostLabels: {
  parent: zone
  name: label
  properties: {
    ttl: 300
    aRecords: [ { ipv4Address: apimPrivateIp } ]
  }
}]

resource link 'Microsoft.Network/privateDnsZones/virtualNetworkLinks@2020-06-01' = {
  parent: zone
  name: 'apim-vnet-link'
  location: 'global'
  properties: {
    registrationEnabled: false
    virtualNetwork: { id: vnetId }
  }
}
