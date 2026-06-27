@description('Location for API Management.')
param location string

@description('APIM service name (globally unique).')
param apimName string

@description('Resource ID of the APIM subnet.')
param apimSubnetId string

@description('Backend ACA app FQDN.')
param appFqdn string

@description('External front-end host (App Gateway public FQDN). Used to set X-Forwarded-Host so Easy Auth builds redirect URIs from the external host, not the internal ACA FQDN.')
param frontendHost string

@description('Deploy APIM in Internal VNet mode (gateway only reachable from inside the VNet). When false, External mode keeps gateway + management endpoints public.')
param apimInternal bool = false

@description('Tags.')
param tags object

@description('Publisher email.')
param publisherEmail string = 'admin@contoso.com'

// VNet integration mode:
// - External: gateway + management endpoints are public, so ARM can configure APIs while the
//   service reaches private (internal ACA) backends over the VNet.
// - Internal: every endpoint is private; the App Gateway fronts the gateway via a private DNS
//   zone (azure-api.net) that maps the gateway host to the service's VNet IP.
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
    virtualNetworkType: apimInternal ? 'Internal' : 'External'
    virtualNetworkConfiguration: {
      subnetResourceId: apimSubnetId
    }
    publicIpAddressId: apimPip.id
  }
}

// API mounted at the gateway root (path '') so the front door can forward '/' straight through.
// A non-root path here is the classic cause of 404s: App Gateway forwards '/' unchanged, but an
// API at '/app' (or any prefix) never matches it.
resource api 'Microsoft.ApiManagement/service/apis@2023-09-01-preview' = {
  parent: apim
  name: 'streamlit-api'
  properties: {
    displayName: 'Streamlit App'
    path: ''
    protocols: [ 'https' ]
    subscriptionRequired: false
    serviceUrl: 'https://${appFqdn}'
  }
}

// Catch-all operations so APIM acts as a transparent reverse proxy. Without at least one
// matching operation APIM returns 404 ("Unable to match incoming request to an operation")
// for every request, regardless of path.
var proxyMethods = [ 'GET', 'POST', 'PUT', 'DELETE', 'PATCH', 'OPTIONS', 'HEAD' ]
resource proxyOps 'Microsoft.ApiManagement/service/apis/operations@2023-09-01-preview' = [for m in proxyMethods: {
  parent: api
  name: 'proxy-${toLower(m)}'
  properties: {
    displayName: '${m} (catch-all)'
    method: m
    urlTemplate: '/*'
    templateParameters: []
    responses: []
  }
}]

// Inbound policy:
// - Host = ACA FQDN so the ACA ingress receives the SNI/Host it expects.
// - X-Forwarded-Host / X-Forwarded-Proto = external host so Easy Auth (forwardProxy=Standard)
//   builds OAuth redirect URIs from the App Gateway host instead of the internal ACA FQDN.
// - No rewrite-uri: the original request path is preserved end to end (needed for Streamlit
//   assets and the /_stcore/stream WebSocket).
resource apiPolicy 'Microsoft.ApiManagement/service/apis/policies@2023-09-01-preview' = {
  parent: api
  name: 'policy'
  properties: {
    format: 'rawxml'
    value: '<policies><inbound><base /><set-backend-service base-url="https://${appFqdn}" /><set-header name="Host" exists-action="override"><value>${appFqdn}</value></set-header><set-header name="X-Forwarded-Host" exists-action="override"><value>${frontendHost}</value></set-header><set-header name="X-Forwarded-Proto" exists-action="override"><value>https</value></set-header></inbound><backend><base /></backend><outbound><base /></outbound><on-error><base /></on-error></policies>'
  }
  dependsOn: [ proxyOps ]
}

output gatewayHostName string = '${apimName}.azure-api.net'

@description('Private VNet IP of the APIM service (only populated in Internal mode).')
output privateIpAddress string = apimInternal ? (first(apim.properties.privateIPAddresses) ?? '') : ''
