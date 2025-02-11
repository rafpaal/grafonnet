local d = import 'github.com/jsonnet-libs/docsonnet/doc-util/main.libsonnet';

{
  local root = self,

  '#getOptionsForCustomQuery':: d.func.new(
    |||
      `getOptionsForCustomQuery` provides values for the `options` and `current` fields.
      These are required for template variables of type 'custom'but do not automatically
      get populated by Grafana when importing a dashboard from JSON.

      This is a bit of a hack and should always be called on functions that set `type` on
      a template variable (see the dashboard.templating.list veneer). Ideally Grafana
      populates these fields from the `query` value but this provides a backwards
      compatible solution.
    |||,
    args=[d.arg('query', d.T.string)],
  ),
  getOptionsForCustomQuery(query): {
    local values = root.parseCustomQuery(query),
    current: root.getCurrentFromValues(values),
    options: root.getOptionsFromValues(values),
  },

  getCurrentFromValues(values): {
    selected: false,
    text: values[0].key,
    value: values[0].value,
  },

  getOptionsFromValues(values):
    std.mapWithIndex(
      function(i, item) {
        selected: i == 0,
        text: item.key,
        value: item.value,
      },
      values
    ),
  parseCustomQuery(query):
    // Break query down to character level
    local split = std.mapWithIndex(
      function(i, c) { index: i, char: c },
      query
    );

    // Split query by comma, unless the comma is escaped
    local items = std.foldl(
      function(acc, item)
        acc
        + (
          // Look for a comma that isn't escaped with '\\'
          if item.char == ','
             && split[item.index - 1].char != '\\'
          then {
            items+: [acc.current_item],
            current_item: '',
          }
          // If this is the last array item, then append the last character
          else if item.index == (std.length(split) - 1)
          then {
            items+: [acc.current_item + item.char],
          }
          // Append characters to current tracking key/value
          else {
            current_item+: item.char,
          }
        ),
      split,
      {
        items: [],
        current_item: '',
      }
    ).items;

    // Split items into key:value pairs
    std.map(
      function(v)
        local split = std.splitLimit(v, ' : ', 1);
        {
          key: std.stripChars(split[0], ' '),
          value:
            if std.length(split) == 2
            then std.stripChars(split[1], ' ')
            else self.key,
        },
      items
    ),
}
