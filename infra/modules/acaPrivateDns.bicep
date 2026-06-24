@description('Default domain of the internal ACA environment.')
param envDefaultDomain string

@description('Static private IP of the internal ACA environment.')
param envStaticIp string

@description('Resource ID of the VNet to link.')
param vnetId string

@description('Tags.')
param tags object = {}

resource zone 'Microsoft.Network/privateDnsZones@2020-06-01' = {
  name: envDefaultDomain
  location: 'global'
  tags: tags
}

resource wildcard 'Microsoft.Network/privateDnsZones/A@2020-06-01' = {
  parent: zone
  name: '*'
  properties: {
    ttl: 300
    aRecords: [ { ipv4Address: envStaticIp } ]
  }
}

resource link 'Microsoft.Network/privateDnsZones/virtualNetworkLinks@2020-06-01' = {
  parent: zone
  name: 'aca-vnet-link'
  location: 'global'
  properties: {
    registrationEnabled: false
    virtualNetwork: { id: vnetId }
  }
}
