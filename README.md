# openmeteo_filter

EmergenceSystem filter that fetches current weather from Open-Meteo. No API key required.


<!-- emergence-context -->
Part of **[EmergenceSystem](https://github.com/EmergenceSystem)** — a distributed
discovery network of small, single-source agents. This filter joins the em_pop gossip
mesh and answers `POST /agent/query`; Emquest fans each query out to many filters in
parallel and aggregates the results.

## API

Queries the [Open-Meteo Forecast API](https://api.open-meteo.com/v1/forecast). Free and open, no registration needed.

## Input

```json
{"latitude": 48.85, "longitude": 2.35}
```

| Field       | Type            | Default | Description              |
|-------------|-----------------|---------|--------------------------|
| `latitude`  | float or string | —       | Latitude (decimal)       |
| `lat`       | float or string | —       | Alias for `latitude`     |
| `longitude` | float or string | —       | Longitude (decimal)      |
| `lon`       | float or string | —       | Alias for `longitude`    |
| `timeout`   | integer         | `10`    | HTTP timeout in seconds  |

## Output

One embryo with current weather conditions:

```json
{
  "properties": {
    "url":       "https://open-meteo.com/en/docs#latitude=48.85&longitude=2.35",
    "resume":    "temperature: 18.3°C, wind: 12.0 km/h, direction: 220°, code: 2",
    "latitude":  "48.85",
    "longitude": "2.35",
    "time":      "2024-01-15T14:00",
    "source":    "api.open-meteo.com"
  }
}
```

## Capabilities

`weather`, `openmeteo`, `forecast`, `meteorology`

## Usage

```bash
rebar3 shell
```

## License

Apache-2.0
