// Parameters for customization
param location string = resourceGroup().location
param appName string = 'HairStylistFeedbackTool'
param environment string = 'dev'

// Resource Group (optional, if deploying to a new group)
resource resourceGroup 'Microsoft.Resources/resourceGroups@2021-04-01' = if (!empty(resourceGroup().name)) {
  name: 'rg-${appName}-${environment}'
  location: location
}

// Azure Static Web Apps for frontend
resource staticWebApp 'Microsoft.Web/staticSites@2022-03-01' = {
  name: '${appName}-static-${environment}'
  location: 'global'
  sku: {
    name: 'Free'
    tier: 'Free'
  }
  properties: {
    repositoryUrl: 'https://github.com/lobsterdiver/hairsite' // Replace with your GitHub repo URL
    branch: 'main'
    buildProperties: {
      appLocation: '/'
      apiLocation: 'api'
      appArtifactLocation: 'build'
    }
  }
}

// Azure Functions for backend logic
resource functionApp 'Microsoft.Web/serverfarms@2021-03-01' = {
  name: '${appName}-plan-${environment}'
  location: location
  sku: {
    name: 'Y1' // Consumption plan (serverless)
    tier: 'Dynamic'
  }
  kind: 'functionapp'
}

resource functionAppHost 'Microsoft.Web/sites@2021-03-01' = {
  name: '${appName}-func-${environment}'
  location: location
  kind: 'functionapp'
  properties: {
    serverFarmId: functionApp.id
    siteConfig: {
      appSettings: [
        { name: 'AzureWebJobsStorage', value: '@Microsoft.Azure.WebJobs.Storage' }
        { name: 'FUNCTIONS_WORKER_RUNTIME', value: 'python' } // Use Node.js; change to 'python' if preferred
      ]
    }
  }
  identity: {
    type: 'SystemAssigned'
  }
  dependsOn: [
    functionApp
  ]
}

// Azure Cosmos DB for data storage
resource cosmosAccount 'Microsoft.DocumentDB/databaseAccounts@2021-10-15' = {
  name: '${appName}-cosmos-${environment}'
  location: location
  kind: 'GlobalDocumentDB'
  properties: {
    databaseAccountOfferType: 'Standard'
    locations: [
      {
        locationName: location
        failoverPriority: 0
        isZoneRedundant: false
      }
    ]
    consistencyPolicy: {
      defaultConsistencyLevel: 'Session'
    }
    enableFreeTier: true // Uses free tier (1,000 RU/s, 25 GB)
  }
}

resource cosmosDatabase 'Microsoft.DocumentDB/databaseAccounts/sqlDatabases@2021-10-15' = {
  parent: cosmosAccount
  name: 'FeedbackDB'
  properties: {
    resource: {
      id: 'FeedbackDB'
    }
  }
}

resource cosmosContainer 'Microsoft.DocumentDB/databaseAccounts/sqlDatabases/containers@2021-10-15' = {
  parent: cosmosDatabase
  name: 'FeedbackContainer'
  properties: {
    resource: {
      id: 'FeedbackContainer'
      partitionKey: {
        paths: ['/stylistId']
        kind: 'Hash'
      }
      indexingPolicy: {
        indexingMode: 'Consistent'
      }
    }
  }
}

// Azure AD B2C for authentication
resource adB2C 'Microsoft.AzureActiveDirectory/b2cDirectories@2021-04-01-preview' = {
  name: '${appName}-b2c-${environment}'
  location: location
  properties: {
    domainName: '${appName}b2c.onmicrosoft.com' // Customize domain
    countryCode: 'US'
    displayName: '${appName} B2C Tenant'
  }
}

// Azure Blob Storage for QR codes
resource storageAccount 'Microsoft.Storage/storageAccounts@2021-09-01' = {
  name: toLower('${appName}storage${environment}')
  location: location
  sku: {
    name: 'Standard_LRS'
  }
  kind: 'StorageV2'
  properties: {
    accessTier: 'Hot'
    supportsHttpsTrafficOnly: true
  }
}

resource blobContainer 'Microsoft.Storage/storageAccounts/blobServices/containers@2021-09-01' = {
  parent: storageAccount
  name: 'qrcodes'
  properties: {
    publicAccess: 'None'
  }
}

// Azure AI Language Service for sentiment analysis
resource aiLanguage 'Microsoft.CognitiveServices/accounts@2021-10-01' = {
  name: '${appName}-ai-${environment}'
  location: location
  sku: {
    name: 'F0' // Free tier
  }
  kind: 'TextAnalytics'
  properties: {}
}

// Azure Notification Hubs for notifications
resource notificationHubNamespace 'Microsoft.NotificationHubs/namespaces@2021-10-01' = {
  name: '${appName}-nh-${environment}'
  location: location
  sku: {
    name: 'Free'
  }
  properties: {}
}

resource notificationHub 'Microsoft.NotificationHubs/namespaces/notificationHubs@2021-10-01' = {
  parent: notificationHubNamespace
  name: 'FeedbackHub'
  properties: {
    apnsCredential: {
      // Placeholder; configure APNs for iOS if needed
    }
    gcmCredential: {
      // Placeholder; configure GCM for Android if needed
    }
  }
}

// Azure Front Door for CDN and load balancing
resource frontDoor 'Microsoft.Network/frontDoors@2020-11-01' = {
  name: '${appName}-frontdoor-${environment}'
  location: 'global'
  properties: {
    frontendEndpoints: [
      {
        name: 'default'
        hostName: '${appName}-frontdoor.azurefd.net'
      }
    ]
    backendPools: [
      {
        name: 'backendPool'
        backends: [
          {
            address: staticWebApp.properties.defaultHostname
            httpPort: 80
            httpsPort: 443
          }
        ]
      }
    ]
    loadBalancingSettings: [
      {
        name: 'loadBalancingSettings'
        sampleSize: 4
        successfulSamplesRequired: 2
      }
    ]
    healthProbeSettings: [
      {
        name: 'healthProbeSettings'
        path: '/'
        protocol: 'Https'
      }
    ]
    routingRules: [
      {
        name: 'routeRule'
        frontendEndpoints: [
          { id: frontDoor.properties.frontendEndpoints[0].id }
        ]
        acceptedProtocols: [ 'Http', 'Https' ]
        patternsToMatch: [ '/*' ]
        routeConfiguration: {
          backendPool: { id: frontDoor.properties.backendPools[0].id }
          cacheConfiguration: {
            queryParameterStripDirective: 'StripAll'
          }
        }
      }
    ]
  }
}

// Azure Monitor and Application Insights
resource appInsights 'Microsoft.Insights/components@2020-02-02' = {
  name: '${appName}-insights-${environment}'
  location: location
  kind: 'web'
  properties: {
    Application_Type: 'web'
    RetentionInDays: 90
  }
}

resource monitorActionGroup 'Microsoft.Insights/actionGroups@2021-09-01' = {
  name: '${appName}-monitor-${environment}'
  location: 'global'
  properties: {
    groupShortName: 'monitor'
    enabled: true
    emailReceivers: [
      {
        name: 'admin'
        emailAddress: 'admin@yourdomain.com' // Replace with your email
        useCommonAlertSchema: true
      }
    ]
  }
}

// Outputs
output staticWebAppUrl string = staticWebApp.properties.defaultHostname
output functionAppUrl string = functionAppHost.properties.defaultHostName
output cosmosEndpoint string = cosmosAccount.properties.documentEndpoint