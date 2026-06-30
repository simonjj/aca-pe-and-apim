@description('Location for all resources.')
param location string

@description('azd environment name.')
param environmentName string

@description('Tags applied to all resources.')
param tags object

@description('Container image for the Streamlit app.')
param streamlitImage string

@description('Deploy the optional APIM tier.')
param deployApim bool

@description('Deploy APIM in Internal VNet mode (gateway reachable only from inside the VNet).')
param apimInternal bool = false

@description('Enable ACA Easy Auth.')
param enableEasyAuth bool

param entraClientId string
param entraTenantId string
@secure()
param entraClientSecret string

var resourceToken = uniqueString(subscription().id, resourceGroup().id, environmentName)
var abbrs = {
  acr: 'cr'
  uami: 'id'
  env: 'cae'
  app: 'ca'
  vnet: 'vnet'
  agw: 'agw'
}

// ---------- Identity + Container Registry ----------
resource uami 'Microsoft.ManagedIdentity/userAssignedIdentities@2023-01-31' = {
  name: '${abbrs.uami}-${resourceToken}'
  location: location
  tags: tags
}

resource acr 'Microsoft.ContainerRegistry/registries@2023-11-01-preview' = {
  name: '${abbrs.acr}${resourceToken}'
  location: location
  tags: tags
  sku: {
    name: 'Basic'
  }
  properties: {
    adminUserEnabled: false
  }
}

var acrPullRoleId = subscriptionResourceId('Microsoft.Authorization/roleDefinitions', '7f951dda-4ed3-4680-a7ca-43fe172d538d')
resource acrPull 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  scope: acr
  name: guid(acr.id, uami.id, acrPullRoleId)
  properties: {
    principalId: uami.properties.principalId
    roleDefinitionId: acrPullRoleId
    principalType: 'ServicePrincipal'
  }
}

// ---------- Network ----------
resource apimNsg 'Microsoft.Network/networkSecurityGroups@2023-11-01' = {
  name: '${abbrs.vnet}-${resourceToken}-apim-nsg'
  location: location
  tags: tags
  properties: {
    securityRules: [
      {
        name: 'Allow-Client-In'
        properties: {
          priority: 100
          direction: 'Inbound'
          access: 'Allow'
          protocol: 'Tcp'
          sourceAddressPrefix: 'VirtualNetwork'
          sourcePortRange: '*'
          destinationAddressPrefix: 'VirtualNetwork'
          destinationPortRanges: [ '443', '80' ]
        }
      }
      {
        name: 'Allow-ApiManagement-Management-In'
        properties: {
          priority: 110
          direction: 'Inbound'
          access: 'Allow'
          protocol: 'Tcp'
          sourceAddressPrefix: 'ApiManagement'
          sourcePortRange: '*'
          destinationAddressPrefix: 'VirtualNetwork'
          destinationPortRange: '3443'
        }
      }
      {
        name: 'Allow-LoadBalancer-In'
        properties: {
          priority: 120
          direction: 'Inbound'
          access: 'Allow'
          protocol: 'Tcp'
          sourceAddressPrefix: 'AzureLoadBalancer'
          sourcePortRange: '*'
          destinationAddressPrefix: 'VirtualNetwork'
          destinationPortRange: '6390'
        }
      }
    ]
  }
}

resource vnet 'Microsoft.Network/virtualNetworks@2023-11-01' = {
  name: '${abbrs.vnet}-${resourceToken}'
  location: location
  tags: tags
  properties: {
    addressSpace: {
      addressPrefixes: [ '10.0.0.0/16' ]
    }
    subnets: [
      {
        name: 'appgw-subnet'
        properties: {
          addressPrefix: '10.0.0.0/24'
        }
      }
      {
        name: 'apim-subnet'
        properties: {
          addressPrefix: '10.0.1.0/24'
          networkSecurityGroup: {
            id: apimNsg.id
          }
        }
      }
      {
        name: 'aca-infra-subnet'
        properties: {
          addressPrefix: '10.0.4.0/23'
          delegations: [
            {
              name: 'aca-delegation'
              properties: {
                serviceName: 'Microsoft.App/environments'
              }
            }
          ]
        }
      }
    ]
  }
}

// ---------- Internal ACA environment ----------
resource acaEnv 'Microsoft.App/managedEnvironments@2024-10-02-preview' = {
  name: '${abbrs.env}-${resourceToken}'
  location: location
  tags: tags
  properties: {
    vnetConfiguration: {
      internal: true
      infrastructureSubnetId: vnet.properties.subnets[2].id
    }
    workloadProfiles: [
      {
        name: 'Consumption'
        workloadProfileType: 'Consumption'
      }
    ]
  }
}

// Private DNS so in-VNet callers (App Gateway / APIM) resolve the app to the env private IP.
module acaDns 'modules/acaPrivateDns.bicep' = {
  name: 'acaDns'
  params: {
    envDefaultDomain: acaEnv.properties.defaultDomain
    envStaticIp: acaEnv.properties.staticIp
    vnetId: vnet.id
    tags: tags
  }
}

// ---------- Streamlit container app ----------
resource app 'Microsoft.App/containerApps@2024-10-02-preview' = {
  name: '${abbrs.app}-streamlit-${resourceToken}'
  location: location
  tags: union(tags, { 'azd-service-name': 'streamlit' })
  identity: {
    type: 'UserAssigned'
    userAssignedIdentities: {
      '${uami.id}': {}
    }
  }
  properties: {
    environmentId: acaEnv.id
    workloadProfileName: 'Consumption'
    configuration: {
      activeRevisionsMode: 'Single'
      registries: [
        {
          server: acr.properties.loginServer
          identity: uami.id
        }
      ]
      ingress: {
        external: true
        targetPort: 8501
        transport: 'auto'
      }
    }
    template: {
      containers: [
        {
          name: 'streamlit'
          image: streamlitImage
          resources: {
            cpu: json('0.5')
            memory: '1Gi'
          }
        }
      ]
      scale: {
        minReplicas: 1
        maxReplicas: 1
      }
    }
  }
  dependsOn: [ acrPull ]
}

resource authConfig 'Microsoft.App/containerApps/authConfigs@2024-10-02-preview' = if (enableEasyAuth) {
  parent: app
  name: 'current'
  properties: {
    platform: {
      enabled: true
    }
    globalValidation: {
      unauthenticatedClientAction: 'RedirectToLoginPage'
      redirectToProvider: 'azureactivedirectory'
    }
    identityProviders: {
      azureActiveDirectory: {
        enabled: true
        registration: {
          clientId: entraClientId
          clientSecretSettingName: 'microsoft-provider-authentication-secret'
          openIdIssuer: '${environment().authentication.loginEndpoint}${entraTenantId}/v2.0'
        }
      }
    }
    httpSettings: {
      requireHttps: true
      forwardProxy: {
        convention: 'Standard'
      }
    }
  }
}

// ---------- Optional APIM tier ----------
// App Gateway public FQDN is deterministic from the PIP domain name label below; compute it as a
// string so the APIM module can reference it without creating a dependency cycle on the gateway.
var agwFrontendFqdn = 'aca-apim-${resourceToken}.${location}.cloudapp.azure.com'

module apim 'modules/apim.bicep' = if (deployApim) {
  name: 'apim'
  params: {
    location: location
    apimName: 'apim-${resourceToken}'
    apimSubnetId: vnet.properties.subnets[1].id
    appFqdn: app.properties.configuration.ingress.fqdn
    frontendHost: agwFrontendFqdn
    apimInternal: apimInternal
    tags: tags
  }
}

// Internal mode: APIM has no public gateway, so the App Gateway resolves <apim>.azure-api.net to
// the service's private VNet IP through this zone. Skipped in External mode (public DNS is used).
module apimDns 'modules/apimPrivateDns.bicep' = if (deployApim && apimInternal) {
  name: 'apimDns'
  params: {
    apimName: 'apim-${resourceToken}'
    apimPrivateIp: apim.outputs.privateIpAddress
    vnetId: vnet.id
    tags: tags
  }
}

// App Gateway backend host: APIM gateway when deployApim, otherwise the ACA app directly.
var backendHost = deployApim ? '${apim.outputs.gatewayHostName}' : app.properties.configuration.ingress.fqdn

// ---------- Application Gateway (WAF_v2, HTTP front) ----------
var agwName = '${abbrs.agw}-${resourceToken}'
var agwPipName = '${abbrs.agw}-pip-${resourceToken}'
var agwId = resourceId('Microsoft.Network/applicationGateways', agwName)

resource wafPolicy 'Microsoft.Network/ApplicationGatewayWebApplicationFirewallPolicies@2023-11-01' = {
  name: 'waf-${resourceToken}'
  location: location
  tags: tags
  properties: {
    policySettings: {
      state: 'Enabled'
      mode: 'Detection'
    }
    managedRules: {
      managedRuleSets: [
        {
          ruleSetType: 'OWASP'
          ruleSetVersion: '3.2'
        }
      ]
    }
  }
}

resource agwPip 'Microsoft.Network/publicIPAddresses@2023-11-01' = {
  name: agwPipName
  location: location
  tags: tags
  sku: {
    name: 'Standard'
  }
  properties: {
    publicIPAllocationMethod: 'Static'
    dnsSettings: {
      domainNameLabel: 'aca-apim-${resourceToken}'
    }
  }
}

resource agw 'Microsoft.Network/applicationGateways@2023-11-01' = {
  name: agwName
  location: location
  tags: tags
  properties: {
    sku: {
      name: 'WAF_v2'
      tier: 'WAF_v2'
      capacity: 1
    }
    firewallPolicy: {
      id: wafPolicy.id
    }
    gatewayIPConfigurations: [
      {
        name: 'appGatewayIpConfig'
        properties: {
          subnet: { id: vnet.properties.subnets[0].id }
        }
      }
    ]
    frontendIPConfigurations: [
      {
        name: 'appGwPublicFrontendIp'
        properties: {
          publicIPAddress: { id: agwPip.id }
        }
      }
    ]
    frontendPorts: [
      {
        name: 'port_80'
        properties: { port: 80 }
      }
    ]
    backendAddressPools: [
      {
        name: 'acaBackendPool'
        properties: {
          backendAddresses: [
            { fqdn: backendHost }
          ]
        }
      }
    ]
    probes: [
      {
        name: 'backendProbe'
        properties: {
          protocol: 'Https'
          host: backendHost
          // Probe APIM's built-in health endpoint when APIM fronts the app; otherwise the app root.
          path: deployApim ? '/status-0123456789abcdef' : '/'
          interval: 30
          timeout: 30
          unhealthyThreshold: 3
          pickHostNameFromBackendHttpSettings: false
          match: {
            // Tightened from 200-499 so a 404 (e.g. an APIM routing miss) no longer reads as
            // "healthy". 302 stays in range for the Easy Auth redirect-to-login response.
            statusCodes: [ '200-399' ]
          }
        }
      }
    ]
    backendHttpSettingsCollection: [
      {
        name: 'backendHttpsSettings'
        properties: {
          port: 443
          protocol: 'Https'
          cookieBasedAffinity: 'Enabled'
          pickHostNameFromBackendAddress: false
          hostName: backendHost
          requestTimeout: 60
          probe: { id: '${agwId}/probes/backendProbe' }
        }
      }
    ]
    httpListeners: [
      {
        name: 'httpListener'
        properties: {
          frontendIPConfiguration: { id: '${agwId}/frontendIPConfigurations/appGwPublicFrontendIp' }
          frontendPort: { id: '${agwId}/frontendPorts/port_80' }
          protocol: 'Http'
        }
      }
    ]
    requestRoutingRules: [
      {
        name: 'routingRule'
        properties: {
          ruleType: 'Basic'
          priority: 100
          httpListener: { id: '${agwId}/httpListeners/httpListener' }
          backendAddressPool: { id: '${agwId}/backendAddressPools/acaBackendPool' }
          backendHttpSettings: { id: '${agwId}/backendHttpSettingsCollection/backendHttpsSettings' }
        }
      }
    ]
  }
}

output registryLoginServer string = acr.properties.loginServer
output registryName string = acr.name
output containerAppName string = app.name
output containerAppFqdn string = app.properties.configuration.ingress.fqdn
output appGatewayUrl string = 'http://${agwPip.properties.dnsSettings.fqdn}/'
