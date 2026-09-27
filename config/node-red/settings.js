/**
 * Node-RED Settings
 * https://nodered.org/docs/user-guide/runtime/configuration
 */

module.exports = {
    // Flow file configuration
    // Path relative to userDir. The FLOWS env var in docker-compose.yml overrides it.
    flowFile: 'flows/flows.json',
    flowFilePretty: true,

    // User directory for storing flows and credentials
    userDir: '/data',

    // Node-RED UI settings
    uiPort: process.env.PORT || 1880,
    uiHost: "0.0.0.0",

    // HTTP admin root
    httpAdminRoot: '/',
    httpNodeRoot: '/',

    // Disable tours for cleaner UI
    tours: false,

    // Editor theme
    editorTheme: {
        projects: {
            enabled: false
        },
        palette: {
            // Allow palette manager
            editable: true
        },
        menu: {
            "menu-item-help": {
                label: "p4n4-iot Documentation",
                url: "https://github.com/raisga/p4n4-iot"
            }
        }
    },

    // Logging configuration
    logging: {
        console: {
            level: "info",
            metrics: false,
            audit: false
        }
    },

    // Function node settings
    functionGlobalContext: {
        // Add global context items here
    },

    // Export global context with flows
    exportGlobalContextKeys: false,

    // Debugging
    debugMaxLength: 1000,

    // MQTT broker defaults (for convenience)
    mqttReconnectTime: 15000,

    // Disable runtime context menu
    contextStorage: {
        default: {
            module: "memory"
        },
        file: {
            module: "localfilesystem"
        }
    }
};
