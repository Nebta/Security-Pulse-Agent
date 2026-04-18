// =============================================================================
// Logic App (Consumption) + Office 365 Outlook API connection.
// =============================================================================
param location string
param customerId string
param recipientEmail string
param senderMailbox string
param scheduleHour int
param scheduleTimeZone string
param sentinelWorkspaceResourceId string
param tenantId string
param userAssignedIdentityResourceId string
param estimatedPricePerGb string
param currencyCode string
param templatesStorageAccountName string
param templatesContainerName string

var logicAppName = 'la-secpulse-${customerId}'
var o365ConnName = 'office365-${customerId}'
var copilotConnName = 'securitycopilot-${customerId}'

resource o365Conn 'Microsoft.Web/connections@2018-07-01-preview' = {
  name: o365ConnName
  location: location
  kind: 'V1'
  properties: {
    displayName: 'O365 Outlook (Security Pulse - ${customerId})'
    api: {
      id: subscriptionResourceId('Microsoft.Web/locations/managedApis', location, 'office365')
    }
  }
}

resource copilotConn 'Microsoft.Web/connections@2018-07-01-preview' = {
  name: copilotConnName
  location: location
  kind: 'V1'
  properties: {
    displayName: 'Security Copilot (Security Pulse - ${customerId})'
    api: {
      id: subscriptionResourceId('Microsoft.Web/locations/managedApis', location, 'Securitycopilot')
    }
    parameterValueSet: {
      name: 'Oauth'
      values: {}
    }
  }
}

resource workflow 'Microsoft.Logic/workflows@2019-05-01' = {
  name: logicAppName
  location: location
  identity: {
    type: 'UserAssigned'
    userAssignedIdentities: {
      '${userAssignedIdentityResourceId}': {}
    }
  }
  properties: {
    state: 'Enabled'
    definition: loadJsonContent('./workflow.json')
    parameters: {
      '$connections': {
        value: {
          office365: {
            connectionId: o365Conn.id
            connectionName: o365ConnName
            id: subscriptionResourceId('Microsoft.Web/locations/managedApis', location, 'office365')
            connectionProperties: {}
          }
          securitycopilot: {
            connectionId: copilotConn.id
            connectionName: copilotConnName
            id: subscriptionResourceId('Microsoft.Web/locations/managedApis', location, 'Securitycopilot')
            connectionProperties: {}
          }
        }
      }
      customerId:                    { value: customerId }
      recipientEmail:                { value: recipientEmail }
      senderMailbox:                 { value: senderMailbox }
      scheduleHour:                  { value: scheduleHour }
      scheduleTimeZone:              { value: scheduleTimeZone }
      sentinelWorkspaceResourceId:   { value: sentinelWorkspaceResourceId }
      tenantId:                      { value: tenantId }
      userAssignedIdentityResourceId:  { value: userAssignedIdentityResourceId }
      estimatedPricePerGb:           { value: estimatedPricePerGb }
      currencyCode:                  { value: currencyCode }
      templatesStorageAccount:       { value: templatesStorageAccountName }
      templatesContainer:            { value: templatesContainerName }
    }
  }
}

output logicAppName string = workflow.name
output logicAppResourceId string = workflow.id
output o365ConnectionResourceId string = o365Conn.id
output copilotConnectionResourceId string = copilotConn.id
