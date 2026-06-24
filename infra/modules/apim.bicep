@description('Location for API Management.')
param location string

@description('APIM service name (globally unique).')
param apimName string

@description('Resource ID of the APIM subnet.')
param apimSubnetId string

@description('Backend ACA app FQDN.')
param appFqdn string

@description('Tags.')
param tags object

@description('Publisher email.')
param publisherEmail string = 'admin@contoso.com'

// External VNet mode: gateway + management endpoints are public, so ARM can configure APIs,
// while the service can still reach private (internal ACA) backends over the VNet.
// NOTE: in network-restricted/corporate subscriptions the APIM management endpoint may be
// unreachable from the APIM resource provider; API config can fail with ManagementApiRequestFailed.
resource apimPip 'Microsoft.Network/publicIPAddresses@2023-11-01' = {
  name: '${apimName}-pip'
  location: location
  tags: tags
  sku: {
    name: 'Standard'
  }
  properties: {
    publicIPAllocationMethod: 'Static'
    dnsSettings: {
      domainNameLabel: apimName
    }
  }
  zones: [ '1', '2', '3' ]
}

resource apim 'Microsoft.ApiManagement/service@2023-09-01-preview' = {
  name: apimName
  location: location
  tags: tags
  sku: {
    name: 'Developer'
    capacity: 1
  }
  properties: {
    publisherEmail: publisherEmail
    publisherName: 'testing-aca-apim'
    virtualNetworkType: 'External'
    virtualNetworkConfiguration: {
      subnetResourceId: apimSubnetId
    }
    publicIpAddressId: apimPip.id
  }
}

resource api 'Microsoft.ApiManagement/service/apis@2023-09-01-preview' = {
  parent: apim
  name: 'streamlit-api'
  properties: {
    displayName: 'Streamlit App'
    path: 'app'
    protocols: [ 'https' ]
    subscriptionRequired: false
    serviceUrl: 'https://${appFqdn}'
  }
}

resource apiPolicy 'Microsoft.ApiManagement/service/apis/policies@2023-09-01-preview' = {
  parent: api
  name: 'policy'
  properties: {
    format: 'rawxml'
    value: '<policies><inbound><base /><set-backend-service base-url="https://${appFqdn}" /><rewrite-uri template="/" /><set-header name="Host" exists-action="override"><value>${appFqdn}</value></set-header></inbound><backend><base /></backend><outbound><base /></outbound><on-error><base /></on-error></policies>'
  }
}

output gatewayHostName string = '${apimName}.azure-api.net'
