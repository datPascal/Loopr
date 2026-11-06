# Loopr data schema

This file describes the two things Loopr writes out of the app: the Your data export and the dashboard files from Publish a page. It is read from the code, not from memory. When a migration or the exporter changes, change this file in the same commit. `DataSchemaDocsTests` fails if a table or a column is missing here.

Sources:

- the exporter, `Loopr/Loopr/App/YourData/YourDataExport.swift`
- the two databases, `Loopr/Loopr/App/PersistentProductRepositories.swift`
- the migrations in `LooprPackages/Sources/StorageKit`, plus the tables ProfileKit and ImportKit create
- the dashboard writer, `LooprPackages/Sources/DataKit/Publish`

## 1. Your data export

### Kinds

Your data offers two kinds. `YourDataExporter.prepare` builds both.

- `everything` writes the SQLite files, one JSON and one CSV file per table, the food photos, the preferences and the integration folders. The Files backup uses this kind too.
- `databases` writes only the SQLite files and `manifest.json`. Its `tables` list is empty.

### Archive layout

The archive is one ZIP named `Loopr-<time>.zip`, where `<time>` is the export time in UTC as ISO 8601 with every `:` replaced by `-`, for example `Loopr-2026-10-25T12-00-00Z.zip`. A copy in a Files folder gets a UUID added to the name, so a backup never replaces an earlier one. The ZIP holds one folder, `Loopr/`:

```
Loopr/
  manifest.json
  products/
    products.sqlite
    <table>.json            one per table, kind everything only
    <table>.csv             one per table, kind everything only
  band-history/
    band-history.sqlite
    <table>.json
    <table>.csv
  photos/
    products/<id>.<ext>     food photos from the food_photo table
    band-history/           only if that database holds food photos
    legacy/                 the old FoodPhotos folder, if it exists
  preferences.plist         kind everything only
  AIKit/                    kind everything only, if the folder exists
  HealthKitBridge/          kind everything only, if the folder exists
  NotificationKit/          kind everything only, if the folder exists
```

If no database wrote a photo, the old FoodPhotos folder is copied to `photos/` itself instead of `photos/legacy/`.

The two database folders come from two files on the phone:

- `products` is the product database, `Application Support/<product file>`. Meals, workouts, protocol, supplements, blood tests, profile and every namespaced product document live here.
- `band-history` is `Application Support/Loopr/loopr.sqlite`. The band ledger, the daily metric series, the Apple Health import cursors and the WHOOP account import live here.

Both files run the same StorageKit migrations, so each one holds every StorageKit table. Most tables in a given file are empty. The sections below say where the data goes in practice.

### `manifest.json`

One JSON object with sorted keys.

- `formatVersion`: `1`. A change to the archive layout or to the side file rules raises it.
- `createdAt`: the export time, ISO 8601, UTC.
- `kind`: `everything` or `databases`.
- `databases`: the folder names, `["products", "band-history"]`.
- `tables`: one entry per table of every database, empty for `databases`. Each entry has `database`, `table`, `columns` (names in table order), `rows` (the row count) and `filename` (the file name without extension).
- `json`: how values map to JSON, in words.
- `csv`: how values map to CSV, in words.
- `excluded`: what the archive leaves out, in words.
- `consistency`: how consistent the snapshot is, in words.

### Side files for every table

`everything` writes `<filename>.json` and `<filename>.csv` for each table in each database. The file name is the table name when it holds only letters, digits, `_` and `-`. Any other name becomes `table-` followed by the hex of its UTF-8 bytes. Every table in this document has a plain name.

The files are written from a read-only connection to the finished SQLite snapshot, so the SQLite, JSON and CSV files agree.

JSON side file:

- one array of objects, one object per row, keys sorted, no pretty printing
- a key is a column name
- SQL NULL is JSON `null`
- an INTEGER stays an integer
- a REAL is a JSON number; infinity or NaN becomes `{"nonFinite": "<text>"}` so the file stays valid JSON
- TEXT is a string
- a BLOB is `{"base64": "<bytes>"}`

CSV side file:

- UTF-8, one header row with the quoted column names, rows end with `\r\n`
- every TEXT value is quoted, with `"` doubled
- INTEGER and REAL values are unquoted
- SQL NULL is an unquoted empty field
- a BLOB is the quoted text `base64:` followed by its Base64 bytes

Most payload columns hold JSON text as a BLOB. In the JSON side file they show as `{"base64": ...}`. Decode the Base64 to get the JSON document.

### Photos

Each row of `food_photo` is written to `photos/<database>/<id>.<ext>`, where the file name is the photo's UUID with `jpg`, `png` or `heic`. The exporter recomputes the SHA-256 of the bytes and stops the export if it differs from the `sha256` column.

### Preferences

`preferences.plist` is an XML property list of the preference keys Loopr owns, for example the onboarding and profile caches, the pinned metrics, the selected tab and the agent access choices. It leaves out the Files backup folder bookmark.

### What the export leaves out

- API keys and other Keychain secrets
- Files folder permission bookmarks
- previous exports and backups
- pending notifications, which live in iOS and not in a file

Different databases and separate files are captured one after another. Each database is one consistent snapshot, but the two databases are not the same instant.

### Time and units

- Instants are Unix time in seconds (seconds since 1970-01-01 00:00:00 UTC). Columns named `*_at`, `timestamp` columns and `absolute_timestamp` use it. Where a column is `INTEGER` the value is whole seconds. Where it is `REAL` it may have a fraction. The one exception is `rr_beat.beat_timestamp_milliseconds` and `route_point.timestamp_milliseconds`, which are milliseconds.
- `local_day`, `collected_day`, `start_day`, `end_day` and `day_id` are civil days as `YYYY-MM-DD`, in the time zone the value was derived in. Loopr does not move a stored day when the person travels. It never rebuilds a day by dividing a timestamp by 86,400.
- Tables that record a moment the person chose carry the IANA time zone too: `lab_report.time_zone_identifier`, `lab_clock_result.time_zone_identifier`, `capacity_result.time_zone_identifier`, `experiment.time_zone_identifier`. Food and routine records carry it inside their JSON payload as `timeZoneIdentifier`.
- Dates inside JSON payloads use Foundation's default coding: a number of seconds since 2001-01-01 00:00:00 UTC. Add 978,307,200 to get Unix seconds.
- `manifest.json` `createdAt` is ISO 8601 in UTC.
- Blood test numbers are TEXT in dot notation, exactly as the lab printed them, whatever the phone's locale.
- Missing means missing. A day without a reading has no row, and an unknown value is NULL. Loopr does not store a stand-in zero.

## 2. SQLite databases

### Migration ledger

`storage_schema_metadata` records each migration with its schema version and the app version that ran it. GRDB keeps its own list in `grdb_migrations`.

| Migration | Schema version | What it adds |
| --- | --- | --- |
| `storage-001-schema-metadata` | 1 | the ledger table |
| `storage-002-sensor-ledger` | 2 | the band ledger tables |
| `storage-003-gen5-beta` | 3 | the `gen5_*` tables |
| `storage-004-release-action-audit` | 4 | `release_action_audit` |
| `storage-005-analytics-revision` | 5 | `analytics_input_revision`, revision triggers |
| `storage-006-analytics-range-revision` | 6 | `analytics_range_revision` |
| `storage-007-v24-adc-fields` | 7 | raw sensor columns on `decoded_second` |
| `storage-008-metric-series-source` | 8 | `source`, `low`, `high` on `metric_series` |
| `storage-009-v24-skin-temperature` | 9 | `skin_temperature_celsius` on `decoded_second` |
| `storage-010-food` | 10 | `food_meal`, `food_photo` |
| `storage-011-food-overview` | 11 | `food_drink`, `food_day`, `food_target` |
| `storage-012-food-capture` | 12 | `food_product_cache`, `food_product_cache_epoch` |
| `storage-013-food-review` | 13 | `food_favorite` |
| `storage-014-train` | 14 | the workout tables |
| `storage-015-food-weight` | 15 | `food_weight` |
| `storage-016-routine` | 16 | the protocol tables |
| `storage-017-labs` | 17 | the blood test tables |
| `storage-019-food-longevity` | 19 | the supplement tables |
| `storage-020-capacity` | 20 | the capacity test tables |
| `storage-021-experiments` | 21 | the experiment tables |
| `storage-022-body-composition` | 22 | `body_composition` |
| `storage-023-lab-value-comparator` | 23 | `comparator` on `lab_value` |

Three tables come from outside StorageKit. ProfileKit adds `profile`, `profile_units` and `profile_goals` to the product database under its own migration `profile-001-canonical`. ImportKit adds the four `whoop_export_*` tables to the history database when the app first opens the WHOOP import store. Document stores add `loopr_product_document` the first time one opens.

### Which tables hold health data

Health data here means readings and records about the body, food, training, medication, blood tests and sleep, plus the location of a route.

These tables hold health data:

- band ledger: `decoded_second`, `rr_beat`, `raw_archive`, `day_result`, `baseline`, `metric_series`, `workout`, `route_point`
- band research and Gen5: `gen5_research_frames`, `gen5_raw_archive`, `gen5_v18_canonical`
- food: `food_meal`, `food_photo`, `food_drink`, `food_day`, `food_target`, `food_favorite`, `food_weight`, `body_composition`
- training: `workout_template`, `workout_program`, `workout_exercise_custom`, `workout_session`, `workout_set`
- protocol: `routine_protocol`, `routine_version`, `routine_check`, `experiment`, `experiment_night`
- supplements and medication: `supplement_item`, `supplement_tick`
- blood tests and capacity tests: `lab_report`, `lab_value`, `lab_clock_result`, `capacity_result`, `capacity_goal`
- WHOOP account import: `whoop_export_row`, `whoop_export_day`, `whoop_export_workout`, `whoop_export_journal`
- profile: `profile`, `profile_units`, `profile_goals` (birth year, sex, height, weight and goals)
- `loopr_product_document`: documents for sleep, heart, body, stress, today, records, cycle, journal, workouts, route, food, coach and agent records

These tables hold bookkeeping only. They hold no readings:

- `storage_schema_metadata`, `grdb_migrations`
- `sync_cursor`, `sync_batch`, `sync_failure`
- `health_import_cursor`, `health_export_item`
- `notification_claim`
- `surface_generation` (a slot for the widget snapshot, not written today)
- `analytics_input_revision`, `analytics_range_revision`
- `gen5_committed_batch`, `gen5_capability_state`, `gen5_band_profile` (band and firmware identity, not readings)
- `food_product_cache`, `food_product_cache_epoch` (public product data from barcode lookups)
- `release_action_audit` (when an export or a deletion ran, and its scope)

### `loopr_product_document` namespaces

`namespace` groups the documents of one feature: `agent`, `body`, `coach`, `cycle`, `daily-analytics`, `data`, `device-center`, `food`, `health-export-analytics`, `health-sync`, `heart`, `journal`, `onboarding`, `patterns`, `records`, `route`, `settings`, `sleep`, `stress`, `today`, `workouts`. A few keys carry meaning for Your data counts: `workouts` keys starting with `workout.`, `journal` keys starting with `habit.day.` (one check-in) and `entry.` (one note), and `food` keys starting with `meal.`. Every payload is JSON.

### Table reference

Types are SQLite storage classes as declared. Every `payload` column is JSON text stored as a BLOB unless the section says otherwise.

#### Ledger and band history

##### `storage_schema_metadata`

- `migration_identifier` (TEXT, primary key): the migration name.
- `schema_version` (TEXT): the schema version that migration produced.
- `application_version` (TEXT): the app version that ran it.

##### `grdb_migrations`

- `identifier` (TEXT, primary key): GRDB's own list of applied migration names. It has no other column.

##### `decoded_second`

One row per second of band history.

- `id` (INTEGER, primary key)
- `physiological_timestamp` (INTEGER, unique): the band's timestamp in seconds.
- `band_counter` (INTEGER): the band's record counter.
- `absolute_timestamp` (INTEGER): Unix seconds.
- `local_day` (TEXT): the local civil day of this second.
- `record_version` (INTEGER): the band record format version.
- `subsecond_ticks` (INTEGER): the band's sub-second tick count.
- `heart_rate` (INTEGER): beats per minute.
- `gravity_x`, `gravity_y`, `gravity_z` (REAL): acceleration along each axis, in g.
- `raw_payload` (BLOB): the record's raw bytes.
- `ppg_green`, `ppg_red_ir` (INTEGER): raw optical sensor counts, from record version 24.
- `skin_contact` (INTEGER): the band's skin contact flag.
- `spo2_red_raw`, `spo2_ir_raw` (INTEGER): raw blood oxygen sensor counts.
- `unidentified_68` (INTEGER): a raw field at byte offset 68 that Loopr has not identified. It was `skin_temp_raw` before migration 9.
- `ambient_raw` (INTEGER): the raw ambient light count.
- `skin_temperature_celsius` (REAL): skin temperature in degrees Celsius, read from byte offset 72 and only stored between 15 and 45.

##### `rr_beat`

- `id` (INTEGER, primary key)
- `decoded_second_id` (INTEGER): the row of `decoded_second` it belongs to. Deleting the second deletes its beats.
- `beat_index` (INTEGER): the beat's position within that second. Unique with `decoded_second_id`.
- `rr_milliseconds` (INTEGER): the interval between beats, in milliseconds.
- `beat_timestamp_milliseconds` (INTEGER): Unix time in milliseconds, nullable.

##### `raw_archive`

- `id` (INTEGER, primary key)
- `raw_payload` (BLOB, unique): the raw record bytes.
- `packet_type` (INTEGER)
- `record_version` (INTEGER)
- `band_counter` (INTEGER)
- `physiological_timestamp` (INTEGER)
- `captured_at` (INTEGER): Unix seconds.
- `reason` (TEXT): why the record was archived.

##### `sync_cursor`

One row, `id` is always 1.

- `id` (INTEGER, primary key)
- `token` (BLOB): the 8-byte band sync token, nullable.
- `counter_high_water` (INTEGER)
- `timestamp_high_water` (INTEGER)
- `updated_at` (INTEGER): Unix seconds.

##### `sync_batch`

- `batch_id` (TEXT, primary key)
- `state` (TEXT): `received`, `committed`, `acked`, `failed` or `redelivered`.
- `token` (BLOB): the 8-byte sync token, nullable.
- `received_at` (INTEGER): Unix seconds.
- `updated_at` (INTEGER): Unix seconds.
- `error` (TEXT): nullable.

##### `sync_failure`

No code writes this table today. It is normally empty.

- `id` (INTEGER, primary key)
- `batch_id` (TEXT)
- `stage` (TEXT)
- `retry_classification` (TEXT)
- `reason` (TEXT)
- `created_at` (INTEGER): Unix seconds.

##### `day_result`

No code writes this table today. It is normally empty.

- `day_id` (TEXT)
- `algorithm_version` (INTEGER)
- `status` (TEXT)
- `payload` (BLOB)
- `computed_at` (INTEGER): Unix seconds.

The primary key is `day_id` with `algorithm_version`.

##### `metric_series`

The daily value of each metric from each source. This is the table behind the charts and behind the dashboard files. Rows are in the history database. A day without a value has no row.

- `local_day` (TEXT): the local civil day.
- `metric_key` (TEXT): the metric, in the units below.
- `source` (TEXT): `band`, `apple_health` or `whoop_export`. Old rows were band rows.
- `value` (REAL): the day's value, nullable.
- `low`, `high` (REAL): the day's lowest and highest value for range charts, nullable.
- `updated_at` (INTEGER): Unix seconds.

The primary key is `metric_key`, `source`, `local_day`. An index covers `local_day`.

Metric keys and units:

| `metric_key` | Unit |
| --- | --- |
| `resting_heart_rate`, `sleeping_heart_rate`, `max_heart_rate` | beats per minute |
| `rmssd`, `sdnn` | milliseconds |
| `pnn50`, `heart_rate_dip`, `oxygen_saturation`, `sleep_efficiency`, `sleep_performance` | percent, 0 to 100 |
| `respiratory_rate` | breaths per minute |
| `skin_temperature_deviation` | degrees Celsius from the person's baseline |
| `recovery`, `stress`, `sleep_consistency` | Loopr score, 0 to 100 |
| `strain` | the 0 to 21 strain scale |
| `sleep_duration`, `sleep_debt`, `deep_sleep`, `rem_sleep` | minutes |
| `vo2_max` | millilitres per kilogram per minute |
| `active_energy` | kilocalories |
| `steps` | count |

When a day has values from more than one source, the app reads the band first, then the WHOOP export, then Apple Health. VO2 max reads Apple Health only. Blood oxygen reads the WHOOP export, then Apple Health.

##### `baseline`

No code writes this table today. It is normally empty.

- `baseline_key` (TEXT)
- `version` (INTEGER)
- `payload` (BLOB)
- `updated_at` (INTEGER): Unix seconds.

The primary key is `baseline_key` with `version`.

##### `workout`

No code writes this table today. Workouts are stored as `workout_*` rows and `loopr_product_document` documents.

- `id` (TEXT, primary key)
- `kind` (TEXT)
- `status` (TEXT)
- `started_at` (INTEGER): Unix seconds, nullable.
- `ended_at` (INTEGER): Unix seconds, nullable.
- `payload` (BLOB)
- `updated_at` (INTEGER): Unix seconds.

##### `route_point`

No code writes this table today. Routes are stored in the `route` namespace of `loopr_product_document`.

- `id` (INTEGER, primary key)
- `workout_id` (TEXT): the row of `workout` it belongs to. Deleting the workout deletes its points.
- `sequence` (INTEGER)
- `timestamp_milliseconds` (INTEGER): Unix time in milliseconds.
- `latitude` (REAL): degrees.
- `longitude` (REAL): degrees.
- `altitude` (REAL): nullable.

##### `health_import_cursor`

Where the Apple Health import stopped for each source.

- `source` (TEXT, primary key)
- `anchor` (BLOB): a small JSON object with `through`, the last imported instant in Unix seconds.
- `updated_at` (INTEGER): Unix seconds.

##### `health_export_item`

No code writes this table today. It is normally empty.

- `object_id` (TEXT, primary key)
- `object_type` (TEXT)
- `status` (TEXT)
- `error` (TEXT)
- `updated_at` (INTEGER): Unix seconds.

##### `notification_claim`

No code writes this table today. It is normally empty.

- `claim_key` (TEXT, primary key)
- `claimed_at` (INTEGER): Unix seconds.

##### `surface_generation`

No code writes this table today. It is normally empty.

- `id` (INTEGER, primary key): always 1.
- `generation` (INTEGER)
- `snapshot` (BLOB)
- `published_at` (INTEGER): Unix seconds.

##### `analytics_input_revision`

One row, `id` is always 1. Triggers on `decoded_second` and `rr_beat` raise `revision` on every change, so cached analytics know when to rebuild.

- `id` (INTEGER, primary key)
- `revision` (INTEGER)

##### `analytics_range_revision`

The same counter per UTC day, so a change recomputes only the days it touches.

- `utc_day` (INTEGER, primary key): the UTC day as a number of days since 1970-01-01.
- `revision` (INTEGER)

##### `release_action_audit`

One row each time an export or a deletion ran.

- `id` (INTEGER, primary key)
- `action` (TEXT): `export` or `deletion`.
- `scope` (TEXT): what the action covered.
- `performed_at` (REAL): Unix seconds.

#### Gen5 band tables

##### `gen5_research_frames`

Raw frames kept apart from the canonical tables.

- `id` (INTEGER, primary key)
- `model` (TEXT)
- `connection_generation` (INTEGER)
- `burst_id` (TEXT)
- `ordinal` (INTEGER): the frame's position in the burst. Unique with the two columns before it.
- `raw_frame` (BLOB)
- `decode_succeeded` (INTEGER): 0 or 1.
- `decode_outcome` (TEXT)
- `marker` (BLOB)
- `token` (BLOB): 8 bytes, nullable.

##### `gen5_raw_archive`

- `id` (INTEGER, primary key)
- `model` (TEXT)
- `raw_payload` (BLOB): unique with `model`.
- `record_version` (INTEGER)

##### `gen5_v18_canonical`

- `id` (INTEGER, primary key)
- `model` (TEXT)
- `physiological_timestamp` (INTEGER): seconds.
- `record_index` (INTEGER): unique with the two columns before it.
- `heart_rate` (INTEGER): beats per minute.
- `rr_le` (BLOB): the RR intervals as little-endian values.
- `gravity_x`, `gravity_y`, `gravity_z` (REAL): acceleration in g.

##### `gen5_committed_batch`

- `model` (TEXT)
- `connection_generation` (INTEGER)
- `burst_id` (TEXT)
- `token` (BLOB): 8 bytes.

The primary key is `model` with `burst_id`.

##### `gen5_capability_state`

- `model` (TEXT)
- `capability` (TEXT)
- `state` (TEXT)
- `firmware` (TEXT): nullable.

The primary key is `model` with `capability`.

##### `gen5_band_profile`

- `peripheral_id` (TEXT, primary key)
- `model` (TEXT)
- `model_confidence` (REAL): 0 to 1.
- `service_uuid` (TEXT)
- `name` (TEXT): nullable.
- `hello_identity` (BLOB): nullable.
- `firmware` (TEXT): nullable.

#### Food

Food payloads are JSON of the Swift model named in each section. Energy is in kilocalories, caffeine in milligrams, alcohol in units of 10 g of pure ethanol, and every other nutrient in grams. An amount of food has its own unit: grams, millilitres, serving or piece. A nutrient that was not reported is absent, and a labelled zero stays zero.

##### `food_meal`

- `id` (TEXT, primary key): the meal's UUID.
- `local_day` (TEXT)
- `occurred_at` (REAL): Unix seconds.
- `revision` (INTEGER): starts at 1.
- `schema_version` (INTEGER)
- `payload` (BLOB): a `FoodMeal` with its slot, time zone, items (name, amount, unit, nutrients, provenance), photo references and note.

##### `food_photo`

- `id` (TEXT, primary key)
- `meal_id` (TEXT): the meal it belongs to. Deleting the meal deletes the photo.
- `media_type` (TEXT): `image/jpeg`, `image/png` or `image/heic`.
- `captured_at` (REAL): Unix seconds.
- `sha256` (TEXT): the hash of `bytes`.
- `bytes` (BLOB): the image.

##### `food_drink`

- `id` (TEXT, primary key)
- `local_day` (TEXT)
- `occurred_at` (REAL): Unix seconds.
- `payload` (BLOB): a `FoodDrink` with its kind, water in millilitres, caffeine, alcohol units and energy.

##### `food_day`

- `local_day` (TEXT, primary key)
- `payload` (BLOB): a `FoodDayRecord` with the day's training allowance and the time the person marked it complete.

##### `food_target`

- `id` (TEXT, primary key)
- `confirmed_at` (REAL): Unix seconds.
- `payload` (BLOB): the person's food targets of that time. Older rows stay, so a past day keeps the targets it had.

##### `food_product_cache`

- `barcode` (TEXT, primary key)
- `fetched_at` (REAL): Unix seconds.
- `payload` (BLOB): a cached Open Food Facts product.

##### `food_product_cache_epoch`

- `id` (INTEGER, primary key): always 1.
- `token` (TEXT): changes when the cache is cleared.

##### `food_favorite`

- `id` (TEXT, primary key)
- `confirmed_at` (REAL): Unix seconds.
- `payload` (BLOB): a saved meal.

##### `food_weight`

- `id` (TEXT, primary key)
- `local_day` (TEXT)
- `measured_at` (REAL): Unix seconds.
- `payload` (BLOB): a `FoodWeightEntry` with `kilograms` between 20 and 400 and the time zone.

##### `body_composition`

Body fat and lean mass typed in next to a weight. One row belongs to one `food_weight` reading and is deleted with it. A row holds at least one of the two values; a value nobody entered is NULL, never 0. There is no `local_day` column, because the weight row carries the day.

- `weight_id` (TEXT, primary key): the `food_weight.id` it belongs to. Deleting the weight deletes this row.
- `body_fat_percent` (REAL, nullable): percent, from 2 to 75.
- `lean_mass_kilograms` (REAL, nullable): kilograms, from 10 to 200.
- `created_at` (REAL): Unix seconds.

#### Training

##### `workout_template`

- `id` (TEXT, primary key)
- `name` (TEXT)
- `updated_at` (REAL): Unix seconds.
- `revision` (INTEGER)
- `schema_version` (INTEGER)
- `payload` (BLOB)

##### `workout_program`

- `id` (TEXT, primary key)
- `name` (TEXT)
- `status` (TEXT): `draft`, `active`, `paused`, `completed` or `archived`.
- `updated_at` (REAL): Unix seconds.
- `revision` (INTEGER)
- `schema_version` (INTEGER)
- `payload` (BLOB)

##### `workout_exercise_custom`

- `key` (TEXT, primary key)
- `name` (TEXT)
- `revision` (INTEGER)
- `schema_version` (INTEGER)
- `payload` (BLOB)

##### `workout_session`

- `id` (TEXT, primary key)
- `local_day` (TEXT)
- `started_at` (REAL): Unix seconds.
- `workout_id` (TEXT): nullable.
- `status` (TEXT): `active`, `completed` or `abandoned`.
- `revision` (INTEGER)
- `schema_version` (INTEGER)
- `payload` (BLOB)

##### `workout_set`

- `id` (TEXT, primary key)
- `session_id` (TEXT): the session it belongs to. Deleting the session deletes its sets.
- `session_exercise_id` (TEXT)
- `exercise_key` (TEXT)
- `position` (INTEGER): 0 or more.
- `logged_at` (REAL): Unix seconds.
- `payload` (BLOB)

#### Protocol and experiments

A protocol is a versioned list of rules. A saved version never changes: a trigger rejects an update. A check belongs to a protocol, a rule key and a day, not to a version.

##### `routine_protocol`

- `id` (TEXT, primary key)
- `name` (TEXT)
- `created_at` (REAL): Unix seconds.
- `is_active` (INTEGER): 1 for the one active protocol, otherwise 0.
- `payload` (BLOB)

##### `routine_version`

- `protocol_id` (TEXT): the protocol it belongs to.
- `version` (INTEGER): 1 or more. Primary key with `protocol_id`.
- `created_at` (REAL): Unix seconds.
- `payload` (BLOB): the rules of that version.

##### `routine_check`

- `protocol_id` (TEXT)
- `rule_key` (TEXT)
- `local_day` (TEXT): the three columns together are the primary key.
- `version` (INTEGER): the version the rule had when the check was decided.
- `state` (TEXT): `kept`, `missed`, `pending` or `unknown`.
- `source` (TEXT): `band`, `food`, `fitness`, `appleHealth` or `manual`.
- `measured_value` (REAL): what the source measured. It is NULL when `state` is `unknown`.
- `overridden` (INTEGER): 1 when the person changed the result by hand.
- `recorded_at` (REAL): Unix seconds.
- `answered_from` (TEXT): `reminder` when the person answered with Done or Skip today on a rule's reminder without opening Loopr. NULL for every other answer and for rows written before migration `storage-025`.

##### `experiment`

One experiment tests one protocol rule on the person's own nights. The columns that define it cannot change after it starts. Only one experiment runs at a time.

- `id` (TEXT, primary key)
- `protocol_id` (TEXT): the protocol it tests.
- `title` (TEXT)
- `intervention_name` (TEXT)
- `rule_key` (TEXT)
- `design` (TEXT): `alternating`, `blocks` or `beforeAfter`.
- `design_length` (INTEGER): the block length. NULL for `alternating`.
- `washout` (INTEGER): washout nights, 0 or more.
- `minimum_nights` (INTEGER): 2 or more.
- `planned_nights` (INTEGER): 2 or more.
- `outcome_key` (TEXT): the metric measured.
- `outcome_title` (TEXT)
- `outcome_unit` (TEXT)
- `outcome_direction` (TEXT): `higher` or `lower`.
- `start_day` (TEXT)
- `time_zone_identifier` (TEXT)
- `created_at` (REAL): Unix seconds.
- `status` (TEXT): `running`, `finished` or `stopped`.
- `end_day` (TEXT): NULL while the experiment runs.

##### `experiment_night`

- `experiment_id` (TEXT): the experiment it belongs to. Deleting the experiment deletes its nights.
- `local_day` (TEXT): the two columns together are the primary key.
- `arm` (TEXT): `on` or `off`.
- `washout` (INTEGER): 1 for a washout night.
- `adherence` (TEXT): `kept`, `missed` or `unknown`.
- `outcome_value` (REAL): NULL when there is no outcome that night.
- `other_values` (TEXT): a JSON object of other measured values, `{}` by default.
- `recorded_at` (REAL): Unix seconds.

#### Supplements and medication

Supplements and medication share two tables. `lane` tells them apart. A tick has no row until the person records it, and only an explicit `skipped` row means skipped.

##### `supplement_item`

- `id` (TEXT, primary key)
- `lane` (TEXT): `supplement` or `medication`.
- `item_key` (TEXT): unique with `lane`.
- `sort_order` (INTEGER)
- `is_active` (INTEGER): 0 or 1.
- `start_day` (TEXT)
- `created_at` (REAL): Unix seconds.
- `payload` (BLOB): the item's name, dose and schedule.

##### `supplement_tick`

- `item_id` (TEXT): the item it belongs to. Deleting the item deletes its ticks.
- `local_day` (TEXT)
- `slot` (TEXT): `morning` or `evening`. The three columns together are the primary key.
- `state` (TEXT): `taken` or `skipped`.
- `recorded_at` (REAL): Unix seconds.
- `note` (TEXT): nullable.

#### Blood tests and capacity tests

Blood tests keep what the lab printed: its range, unit and flag. Loopr never classifies a value.

##### `lab_report`

- `id` (TEXT, primary key)
- `collected_at` (REAL): Unix seconds.
- `collected_day` (TEXT): the day in `time_zone_identifier`. It is not named `local_day`, so deleting a day of band data never deletes a blood test.
- `time_zone_identifier` (TEXT)
- `lab_name` (TEXT): nullable.
- `fasting` (INTEGER): 0 or 1, NULL when unknown.
- `source` (TEXT): `typed` or `scan`.
- `created_at` (REAL): Unix seconds.
- `note` (TEXT): nullable.

##### `lab_value`

- `id` (TEXT, primary key)
- `report_id` (TEXT): the report it belongs to. Deleting the report deletes its values.
- `position` (INTEGER): the order the values were saved in.
- `marker_key` (TEXT): a marker Loopr knows by name. Exactly one of `marker_key` and `other_name` is set.
- `other_name` (TEXT): the lab's own name for a marker Loopr does not list.
- `assay` (TEXT): the assay note, for example `hs-CRP`.
- `value_text` (TEXT): the number in dot notation.
- `printed_value` (TEXT): the digits as printed, when they differ from `value_text`, for example `5.0`.
- `comparator` (TEXT): the sign the lab printed before a result given as a limit: `<`, `<=`, `>` or `>=`. A result printed `<0.3` stores `<` here and `0.3` in `value_text`. NULL is an exact result. Blood age does not use a value with a sign. Added by `storage-023-lab-value-comparator`.
- `unit` (TEXT): the unit as printed. Loopr never fills one in.
- `reference_low`, `reference_high` (TEXT): the lab's range bounds in dot notation.
- `reference_text` (TEXT): a range printed as text, such as `<5.0`.
- `flag_text` (TEXT): the lab's own flag, such as `H`.
- `source` (TEXT): `typed` or `scan`.
- `scan_confidence` (REAL): 0 to 1, only for scanned values.
- `needs_review` (INTEGER): 1 for a scanned value the person has not checked.

##### `lab_clock_result`

A result from a lab that reports an aging clock.

- `id` (TEXT, primary key)
- `clock_kind` (TEXT): `dunedinpace`, `grimage` or `other`.
- `clock_name` (TEXT): set only when `clock_kind` is `other`.
- `value_text` (TEXT): the number in dot notation.
- `unit` (TEXT): nullable.
- `lab_name` (TEXT)
- `collected_at` (REAL): Unix seconds.
- `time_zone_identifier` (TEXT)
- `created_at` (REAL): Unix seconds.
- `note` (TEXT): nullable.

##### `capacity_result`

One result of a capacity test. The table has no `local_day`, so deleting a day of band data keeps the test.

- `id` (TEXT, primary key)
- `test_kind` (TEXT): `grip`, `dead_hang`, `sit_to_stand`, `one_leg_balance` or `heart_rate_recovery`.
- `value` (REAL): 0 to 1000, in the unit below.
- `unit` (TEXT): `kg` for grip, `s` for dead hang and one-leg balance, `points` for sit to stand, `bpm` for heart rate recovery.
- `side` (TEXT): `left` or `right`. Grip and one-leg balance have a side, the other tests have none.
- `recorded_at` (REAL): Unix seconds.
- `time_zone_identifier` (TEXT)
- `source` (TEXT): `typed` for grip and sit to stand, `timed` for dead hang and one-leg balance, `workout` for heart rate recovery.
- `workout_id` (TEXT): set only when `source` is `workout`, and unique.
- `algorithm_version` (TEXT): set only when `source` is `workout`.
- `created_at` (REAL): Unix seconds.

##### `capacity_goal`

- `test_kind` (TEXT, primary key): the same five kinds as `capacity_result`.
- `target_value` (REAL): above 0, up to 1000.
- `unit` (TEXT): the same unit rule as `capacity_result`.
- `set_at` (REAL): Unix seconds.

#### Profile

##### `profile`

- `id` (TEXT, primary key)
- `display_name` (TEXT)
- `birth_year` (INTEGER): nullable.
- `biological_sex` (TEXT): nullable.
- `height_centimeters` (REAL): nullable.
- `weight_kilograms` (REAL): nullable.
- `timezone_identifier` (TEXT): nullable.
- `created_at` (REAL): Unix seconds.
- `updated_at` (REAL): Unix seconds.

##### `profile_units`

- `profile_id` (TEXT, primary key): the profile it belongs to. Deleting the profile deletes this row.
- `unit_system` (TEXT)
- `updated_at` (REAL): Unix seconds.

##### `profile_goals`

- `id` (TEXT, primary key)
- `profile_id` (TEXT): nullable, because a goal can be saved before the profile is complete.
- `type` (TEXT)
- `target` (REAL)
- `unit` (TEXT)
- `is_enabled` (INTEGER): 0 or 1.
- `updated_at` (REAL): Unix seconds.

#### Documents and the WHOOP account import

##### `loopr_product_document`

- `namespace` (TEXT): the feature that owns the document.
- `document_key` (TEXT): the two columns together are the primary key.
- `payload` (BLOB): JSON with sorted keys.
- `updated_at` (REAL): Unix seconds.

An index covers `namespace`.

##### `whoop_export_row`

One row of a WHOOP account export file: a cycle, a sleep, a workout or a journal answer.

- `id` (TEXT, primary key)
- `kind` (TEXT): `cycle`, `sleep`, `workout` or `journal`.
- `local_day` (TEXT)
- `start` (REAL): the row's start time in Unix seconds.
- `payload` (BLOB)

Indexes cover (`local_day`, `kind`) and (`kind`, `start`).

##### `whoop_export_day`

- `local_day` (TEXT, primary key)
- `payload` (BLOB): the imported daily summary.

##### `whoop_export_workout`

- `id` (TEXT, primary key)
- `local_day` (TEXT)
- `start` (REAL): Unix seconds.
- `payload` (BLOB)

An index covers `start`.

##### `whoop_export_journal`

- `id` (TEXT, primary key)
- `local_day` (TEXT)
- `payload` (BLOB)

## 3. Dashboard export (Publish a page)

Publish a page writes two files from the metrics the person picks. The person previews them in the app and saves them through the share sheet. Nothing is uploaded. Both files come from one value, so they never disagree.

- `loopr-dashboard.html` is one self-contained page: inline CSS, inline SVG sparklines, no script, no font, no image, no link and no tracker. It follows the phone's light or dark setting through `prefers-color-scheme`. Each metric shows its name, unit, latest value, average, a sparkline and its source. The footer says "Made with Loopr", gives the export date and says "Loopr is not a medical device."
- `loopr-dashboard.json` holds the same numbers for a program to read.

Schema version 1. The JSON uses sorted keys, two-space indentation and no escaped slashes.

### JSON layout

Top level:

- `schemaVersion` (integer): `1`. A change to a key's meaning or removal of a key raises it. Adding a key does not.
- `generator` (string): `Loopr`.
- `exportedAt` (string): the export instant, ISO 8601 in UTC, whole seconds, for example `2026-10-25T12:00:00Z`.
- `timeZone` (string): the IANA time zone of the phone at export. Every `date` below is a calendar day in this zone.
- `period` (object): the span of days published.
  - `id`: `days30`, `days90` or `months12`.
  - `days`: `30`, `90` or `365`. Twelve months is 365 days.
  - `from`, `through`: the first and last day, `YYYY-MM-DD`, both included. `through` is the local day of `exportedAt`.
- `includesBloodTests` (boolean): `true` only if the person switched blood test values on. It is off by default.
- `metrics` (array): the picked metrics, ordered by group (Sleep, Heart, Fitness, Food, Blood tests, Protocol) and then by name.

Each metric:

- `key` (string): the stable key. See the next section.
- `name` (string): the name shown in the app.
- `unit` (string): the unit of `value`. Empty when the metric has none.
- `group` (string): `Sleep`, `Heart`, `Fitness`, `Food`, `Blood tests` or `Protocol`.
- `source` (string): where the numbers came from, for example `WHOOP band`, `Apple Health`, `WHOOP account export`, `Loopr food log`, `Loopr protocol` or `Blood test reports`. A metric with more than one source lists them, separated by commas.
- `values` (array): one object per day with a reading, oldest first.
  - `date`: the local day, `YYYY-MM-DD`.
  - `value`: a finite number in `unit`.

A day without a reading is left out of `values`. It is never written as `0`. A picked metric with no reading in the period stays in the file with an empty `values` array.

Example, shortened onto fewer lines than the real file:

```json
{
  "exportedAt" : "2026-10-25T12:00:00Z",
  "generator" : "Loopr",
  "includesBloodTests" : false,
  "metrics" : [
    {
      "group" : "Heart",
      "key" : "resting_heart_rate",
      "name" : "Resting heart rate",
      "source" : "WHOOP band",
      "unit" : "bpm",
      "values" : [
        { "date" : "2026-10-23", "value" : 52 },
        { "date" : "2026-10-25", "value" : 53 }
      ]
    }
  ],
  "period" : {
    "days" : 30,
    "from" : "2026-09-26",
    "id" : "days30",
    "through" : "2026-10-25"
  },
  "schemaVersion" : 1,
  "timeZone" : "UTC"
}
```

### Metric keys

Sleep, Heart and Fitness keys are the `metric_key` values of `metric_series`, with the units listed there. In the dashboard a count is `steps`, and a score is `score`. Names are the ones the app shows.

| Group | Keys |
| --- | --- |
| Sleep | `sleep_duration`, `sleep_performance`, `sleep_debt`, `sleep_efficiency`, `deep_sleep`, `rem_sleep`, `sleep_consistency` |
| Heart | `resting_heart_rate`, `rmssd`, `sdnn`, `pnn50`, `respiratory_rate`, `sleeping_heart_rate`, `heart_rate_dip`, `oxygen_saturation`, `skin_temperature_deviation`, `recovery`, `stress` |
| Fitness | `strain`, `vo2_max`, `max_heart_rate`, `active_energy`, `steps` |

Other keys:

- Food: `food_energy` (Calories, `kcal`), `food_protein` (Protein, `g`), `food_fibre` (Fibre, `g`). A day counts only when every meal item and drink of that day reports the nutrient, so a partly logged day never shows as a low total. Days with a total of 0 are left out.
- Protocol: `protocol_rules_kept` (Protocol rules kept, `rules`). The number of rules marked kept that day in the active protocol. A day with no kept or missed check is left out.
- Blood tests: `lab_` followed by the marker key with `-` replaced by `_`, for example `lab_apob`. A marker the lab named in its own words becomes `lab_other_` followed by its name in lowercase letters and digits. The unit is the one on the latest report. A value printed in another unit is left out, so a series never mixes units. The day is the report's `collected_day`, and two reports on one day keep the later value. Blood test series appear only when `includesBloodTests` is `true`.

### Rules

- Only picked metrics are in either file. Nothing else is read into them.
- Values outside the period, repeated days and numbers that are not finite are dropped.
- A sparkline joins two readings with a line when they are at most three days apart. Blood test readings are weeks apart, so their line always joins them. A single reading is a dot.
- The HTML escapes every text it prints. The page has no `href`, `src`, `url()`, `@import` or script, and a Content-Security-Policy meta tag allows inline styles and nothing else.
- The preview in the app loads the HTML string with subresources and JavaScript off, and refuses every navigation away from the page.
- The two files go to a folder under the phone's temporary directory, and the app removes that folder when the screen closes and on the next visit.

## 4. Keeping this file correct

`LooprPackages/Tests/DataKitTests/Publish/DataSchemaDocsTests.swift` checks that:

- every table StorageKit requires, every table a fresh database holds, and the tables ProfileKit, ImportKit and the document store add are named here
- every column of every required table is named in that table's section
- the manifest keys and the dashboard JSON keys appear

It cannot check the prose. When a column changes meaning, update the sentence.
