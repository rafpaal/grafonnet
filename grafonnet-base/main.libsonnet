local crdsonnet = import 'github.com/crdsonnet/crdsonnet/crdsonnet/main.libsonnet';
local d = import 'github.com/jsonnet-libs/docsonnet/doc-util/main.libsonnet';
local xtd = import 'github.com/jsonnet-libs/xtd/main.libsonnet';

local util = import './util/main.libsonnet';
local veneer = import './veneer/main.libsonnet';

{
  local root = self,

  // Used to fake render missing schemas
  local genericSchema(title) =
    root.restructure({
      info: {
        title: title,
      },
      components: {
        schemas: {
          [title]: {
            type: 'object',
          },
        },
      },
    }),

  new(schemas, version):
    local dashboardSchema = std.filter(
      function(schema) schema.info.title == 'dashboard',
      schemas
    )[0];

    local allSchemaTitles = std.map(function(x) x.info.title, schemas);

    local filteredSchemas = {
      core: std.filterMap(
        function(schema)
          !std.endsWith(schema.info.title, 'PanelCfg')
          && !std.endsWith(schema.info.title, 'DataQuery'),
        function(schema) root.restructure(schema),
        schemas
      ),

      local missingPanelSchemas = [
        'CandlestickPanelCfg',
        'CanvasPanelCfg',
      ],
      panel:
        [
          genericSchema(title)
          for title in missingPanelSchemas
          if !std.member(allSchemaTitles, title)
        ]
        + std.filterMap(
          function(schema) std.endsWith(schema.info.title, 'PanelCfg'),
          function(schema) root.restructure(schema),
          schemas
        ),

      query: std.filterMap(
        function(schema) std.endsWith(schema.info.title, 'DataQuery'),
        function(schema) root.restructure(schema),
        schemas,
      ),
    };

    {
      [schema.info.title]:
        root.coreLib.new(schema)
        + root.packageDocMixin(version, schema.info.title, '')
        + veneer.core(schema.info.title)
      for schema in filteredSchemas.core
    }
    + {
      [k]:
        {
          [schema.info.title]:
            root[k + 'Lib'].new(dashboardSchema, schema)
            + root.packageDocMixin(version, schema.info.title, k + '.')
            + veneer[k](schema.info.title)
          for schema in filteredSchemas[k]
        }
        + root.packageDocMixin(version, k, '')
      for k in std.objectFields(filteredSchemas)
      if k != 'core'
    }
    + {
      // Move rowPanel schema to panels
      local rowPanel =
        root.restructure({
          info: {
            title: 'RowPanelCfg',
          },
          components: {
            schemas:
              dashboardSchema.components.schemas
              {
                RowPanelCfg:
                  dashboardSchema.components.schemas.RowPanel
                  { properties+: { panels+: { items: {} } } },
              },
          },
        }),

      panel+: {
        row:
          root.coreLib.new(rowPanel)
          + root.packageDocMixin(version, 'row', 'panel.')
          + veneer.panel('row'),
      },

      // Add docs
      '#':
        d.package.new(
          'grafonnet',
          'github.com/grafana/grafonnet/gen/grafonnet-%s' % version,
          'Jsonnet library for rendering Grafana resources',
          'main.libsonnet',
          'main',
        ),

      // Add util functions
      util: util,
    },


  packageDocMixin(version, name, path):
    {
      '#':
        d.package.newSub(
          name,
          'grafonnet.%(path)s%(name)s' % { version: version, name: name, path: path }
        ),
    },

  formatPanelName(name):
    local woDataQuery = std.strReplace(name, 'DataQuery', '');
    local woPanelCfg = std.strReplace(woDataQuery, 'PanelCfg', '');
    local split = xtd.camelcase.split(woPanelCfg);
    std.join(
      '',
      [std.asciiLower(split[0])]
      + split[1:]
    ),

  restructure(schema):
    local title = schema.info.title;
    local formatted = root.formatPanelName(title);

    local schemaFixes = {
      CloudWatchDataQuery: {
        [formatted]: {
          type: 'object',
          oneOf: [
            { '$ref': '#/components/schemas/CloudWatchAnnotationQuery' },
            { '$ref': '#/components/schemas/CloudWatchLogsQuery' },
            { '$ref': '#/components/schemas/CloudWatchMetricsQuery' },
          ],
        },
      },
      AzureMonitorDataQuery: {
        [formatted]: {
          '$ref': '#/components/schemas/AzureMonitorQuery',
        },
      },
      TempoDataQuery: {
        [formatted]: {
          '$ref': '#/components/schemas/TempoQuery',
        },
      },
    };

    schema {
      info+: {
        title: formatted,
      },
      components+: {
        schemas+:
          // FIXME: Some schemas follow a different structure,  temporarily covering for this.
          std.get(
            schemaFixes,
            title,
            { [formatted]: super[title] }
          ),
      },
    }
  ,

  docs(main):
    d.render(main),

  coreLib: {
    new(schema):
      local title = schema.info.title;  //std.trace(schema.info.title, schema.info.title);
      local render = crdsonnet.fromOpenAPI(
        'lib',
        schema.components.schemas[title],
        schema,
        render='dynamic',
      );
      if 'lib' in render
      then render.lib
      else {},
  },

  queryLib: {
    new(dashboardSchema, schema):
      local title = schema.info.title;  //std.trace(schema.info.title, schema.info.title);
      local render = crdsonnet.fromOpenAPI(
        'lib',
        schema.components.schemas[title],
        schema,
        render='dynamic',
      );
      if 'lib' in render
      then render.lib
      else {},
  },

  panelLib: {
    // Some plugins are named differently, this has been resolved in the Grafana code base
    // but no reflected in the JSON schema.
    // source: https://github.com/grafana/grafana/blob/0ee9d11a9148f517fed57bd4c9b840480993cf42/pkg/kindsys/report.go#L285
    local irregularPluginNames = {
      // Panel
      alertgroups: 'alertGroups',
      annotationslist: 'annolist',
      dashboardlist: 'dashlist',
      nodegraph: 'nodeGraph',
      statetimeline: 'state-timeline',
      statushistory: 'status-history',
      tableold: 'table-old',
      // Datasource
      googlecloudmonitoring: 'cloud-monitoring',
      azuremonitor: 'grafana-azure-monitor-datasource',
      microsoftsqlserver: 'mssql',
      postgresql: 'postgres',
    },

    // The panelSchema has PanelOptions and PanelFieldConfig that need to replace certain
    // fiels in the upstream Panel schema This function fits these schemas in the right
    // place for CRDsonnet.
    new(dashboardSchema, panelSchema):
      local subSchema = panelSchema.components.schemas[panelSchema.info.title];
      local customSubSchema =
        panelSchema.components.schemas[panelSchema.info.title] {
          type: 'object',
          [if 'properties' in subSchema then 'properties']+: {
            [if 'PanelOptions' in subSchema.properties then 'options']:
              subSchema.properties.PanelOptions,
            [if 'PanelFieldConfig' in subSchema.properties then 'fieldConfig']: {
              type: 'object',
              properties+: {
                defaults+: {
                  type: 'object',
                  properties+: {
                    custom: subSchema.properties.PanelFieldConfig,
                  },
                },
              },
            },
          },
        };

      local customPanelSchema =
        dashboardSchema.components.schemas.Panel {
          properties+: {
            type: {
              const:
                std.get(
                  irregularPluginNames,
                  std.asciiLower(panelSchema.info.title),
                  std.asciiLower(panelSchema.info.title)
                ),
            },
          },
        };

      local parsed =
        crdsonnet.fromOpenAPI(
          'customLib',
          customSubSchema,
          panelSchema,
          render='dynamic',
        )
        + crdsonnet.fromOpenAPI(
          'panelLib',
          customPanelSchema,
          dashboardSchema,
          render='dynamic',
        );

      parsed.panelLib {
        [if 'options' in parsed.customLib then 'options']:
          parsed.customLib.options,
        [if 'fieldConfig' in parsed.customLib then 'fieldConfig']+: {
          defaults+: {
            [if 'custom' in parsed.customLib.fieldConfig.defaults then 'custom']:
              parsed.customLib.fieldConfig.defaults.custom,
          },
        },
      },
  },
}
