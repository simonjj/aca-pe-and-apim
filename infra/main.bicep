targetScope = 'subscription'

@minLength(1)
@maxLength(64)
@description('Name of the azd environment (used for tagging and resource naming).')
param environmentName string

@minLength(1)
@description('Primary Azure region for all resources.')
param location string

@description('Resource group to deploy into.')
param resourceGroupName string = 'testing-aca-apim'

@description('Initial container image. azd overwrites this with the image built from ./src during "azd deploy".')
param streamlitImage string = 'mcr.microsoft.com/azuredocs/containerapps-helloworld:latest'

@description('Deploy the optional API Management tier (App Gateway -> APIM -> ACA). Default false. See README "Limitations": in network-restricted/corporate subscriptions the APIM management endpoint can be unreachable and API config will fail.')
param deployApim bool = false

@description('Enable ACA Easy Auth (Entra). Requires an app registration; see README.')
param enableEasyAuth bool = false

@description('Entra application (client) ID for Easy Auth.')
param entraClientId string = ''

@description('Entra tenant ID for Easy Auth.')
param entraTenantId string = ''

@secure()
@description('Entra application client secret for Easy Auth.')
param entraClientSecret string = ''

var tags = {
  'azd-env-name': environmentName
}

resource rg 'Microsoft.Resources/resourceGroups@2024-03-01' = {
  name: resourceGroupName
  location: location
  tags: tags
}

module resources 'resources.bicep' = {
  scope: rg
  name: 'resources'
  params: {
    location: location
    environmentName: environmentName
    tags: tags
    streamlitImage: streamlitImage
    deployApim: deployApim
    enableEasyAuth: enableEasyAuth
    entraClientId: entraClientId
    entraTenantId: entraTenantId
    entraClientSecret: entraClientSecret
  }
}

// Outputs consumed by azd (azd deploy uses the registry + service name).
output AZURE_CONTAINER_REGISTRY_ENDPOINT string = resources.outputs.registryLoginServer
output AZURE_CONTAINER_REGISTRY_NAME string = resources.outputs.registryName
output AZURE_RESOURCE_GROUP string = rg.name
output SERVICE_STREAMLIT_NAME string = resources.outputs.containerAppName
output APPLICATION_GATEWAY_URL string = resources.outputs.appGatewayUrl
output CONTAINER_APP_FQDN string = resources.outputs.containerAppFqdn
