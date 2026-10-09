-- TP5 : schéma fourni, sans implémentation de l'API ni requêtes de dashboard.
-- Exécuter avec psql dans la base steam_api, en tant qu'administrateur.
-- Réexécutable sur ce même schéma ; ce fichier n'est pas un outil de migration.
\set ON_ERROR_STOP on
\getenv api_password API_DB_PASSWORD
\getenv grafana_password GRAFANA_DB_PASSWORD

BEGIN;

DO $roles$
BEGIN
    IF NOT EXISTS (SELECT FROM pg_roles WHERE rolname = 'api_writer') THEN
        CREATE ROLE api_writer LOGIN;
    END IF;
    IF NOT EXISTS (SELECT FROM pg_roles WHERE rolname = 'grafana_reader') THEN
        CREATE ROLE grafana_reader LOGIN;
    END IF;
END
$roles$;

ALTER ROLE api_writer PASSWORD :'api_password';
ALTER ROLE grafana_reader PASSWORD :'grafana_password';
ALTER ROLE grafana_reader SET statement_timeout = '10s';
ALTER ROLE grafana_reader SET default_transaction_read_only = on;
REVOKE ALL ON DATABASE steam_api FROM PUBLIC;
GRANT CONNECT ON DATABASE steam_api TO api_writer, grafana_reader;
REVOKE CREATE ON SCHEMA public FROM PUBLIC;
CREATE SCHEMA IF NOT EXISTS tracing;
REVOKE ALL ON SCHEMA tracing FROM PUBLIC;
GRANT USAGE ON SCHEMA tracing TO api_writer, grafana_reader;

CREATE OR REPLACE FUNCTION tracing.valid_owner_range(value text)
RETURNS boolean LANGUAGE sql IMMUTABLE STRICT AS $function$
    SELECT CASE
        WHEN value ~ '^[0-9]{1,20} - [0-9]{1,20}$'
        THEN split_part(value, ' - ', 1)::numeric < split_part(value, ' - ', 2)::numeric
        ELSE false
    END
$function$;
REVOKE ALL ON FUNCTION tracing.valid_owner_range(text) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION tracing.valid_owner_range(text) TO api_writer, grafana_reader;

CREATE TABLE IF NOT EXISTS tracing.model_versions (
    model_id uuid PRIMARY KEY,
    task text NOT NULL CHECK (task IN ('regression', 'classification')),
    tracking_uri text NOT NULL CHECK (length(tracking_uri) > 0),
    registered_name text NOT NULL CHECK (length(registered_name) > 0),
    version bigint NOT NULL CHECK (version > 0),
    mlflow_run_id text NOT NULL CHECK (length(mlflow_run_id) > 0),
    model_uri text NOT NULL CHECK (length(model_uri) > 0),
    created_at timestamptz NOT NULL DEFAULT now(),
    UNIQUE (tracking_uri, registered_name, version),
    UNIQUE (model_id, task)
);
COMMENT ON TABLE tracing.model_versions IS
    'Identité exacte chargée depuis MLflow. Insérer une fois ; ne pas stocker seulement un alias mutable.';

CREATE TABLE IF NOT EXISTS tracing.api_requests (
    request_id uuid PRIMARY KEY,
    started_at timestamptz NOT NULL,
    recorded_at timestamptz NOT NULL DEFAULT clock_timestamp(),
    endpoint text NOT NULL CHECK (endpoint IN ('/predict', '/predict/batch', '/feedback')),
    http_status smallint NOT NULL CHECK (http_status BETWEEN 200 AND 599),
    item_count integer CHECK (item_count >= 0),
    processing_duration_ms double precision NOT NULL
        CHECK (processing_duration_ms >= 0 AND processing_duration_ms < 'Infinity'::double precision),
    inference_duration_ms double precision
        CHECK (inference_duration_ms >= 0 AND inference_duration_ms < 'Infinity'::double precision),
    worker_pid integer NOT NULL CHECK (worker_pid > 0),
    instance_id uuid NOT NULL,
    api_revision text NOT NULL CHECK (length(api_revision) > 0),
    campaign_id text NOT NULL DEFAULT 'manual' CHECK (length(campaign_id) BETWEEN 1 AND 128),
    error_code text,
    CHECK ((http_status < 400 AND error_code IS NULL) OR
           (http_status >= 400 AND error_code IS NOT NULL)),
    CHECK (http_status >= 400 OR endpoint = '/feedback' OR
           (item_count IS NOT NULL AND item_count BETWEEN 1 AND 100)),
    CHECK (http_status >= 400 OR endpoint <> '/predict' OR item_count = 1)
);
COMMENT ON COLUMN tracing.api_requests.processing_duration_ms IS
    'Horloge monotone : entrée dans le traitement HTTP jusqu avant la transaction de traçabilité finale. Exclut son commit et le transport réseau.';
COMMENT ON COLUMN tracing.api_requests.inference_duration_ms IS
    'Temps cumulé des deux appels predict pour toute la requête ; jamais à diviser pour inventer un percentile par jeu.';
COMMENT ON COLUMN tracing.api_requests.instance_id IS
    'UUID créé à chaque démarrage de worker ; différencie les redémarrages avec réutilisation du même PID.';
COMMENT ON TABLE tracing.api_requests IS
    'Une ligne par tentative HTTP sur les trois endpoints métier, y compris 4xx/5xx quand la base est disponible.';

CREATE TABLE IF NOT EXISTS tracing.predictions (
    prediction_id uuid PRIMARY KEY,
    request_id uuid NOT NULL REFERENCES tracing.api_requests(request_id),
    item_index integer NOT NULL CHECK (item_index BETWEEN 0 AND 99),
    appid bigint CHECK (appid > 0),
    task text NOT NULL CHECK (task IN ('regression', 'classification')),
    model_id uuid NOT NULL,
    input_features jsonb NOT NULL CHECK (jsonb_typeof(input_features) = 'object'),
    predicted_pct double precision,
    predicted_owners text,
    created_at timestamptz NOT NULL DEFAULT now(),
    FOREIGN KEY (model_id, task) REFERENCES tracing.model_versions(model_id, task),
    UNIQUE (request_id, item_index, task),
    UNIQUE (prediction_id, task),
    CHECK (
        (task = 'regression' AND predicted_pct IS NOT NULL AND
         predicted_pct BETWEEN 0 AND 100 AND predicted_owners IS NULL)
        OR
        (task = 'classification' AND predicted_pct IS NULL AND predicted_owners IS NOT NULL AND
         tracing.valid_owner_range(predicted_owners))
    )
);
COMMENT ON TABLE tracing.predictions IS
    'Une ligne par jeu ET par tâche : une requête valide de N jeux produit 2N lignes. Entrées limitées aux features utiles.';

CREATE TABLE IF NOT EXISTS tracing.feedbacks (
    feedback_id uuid PRIMARY KEY,
    request_id uuid NOT NULL UNIQUE REFERENCES tracing.api_requests(request_id),
    prediction_id uuid NOT NULL UNIQUE,
    task text NOT NULL CHECK (task IN ('regression', 'classification')),
    useful boolean,
    observed_pct double precision,
    observed_owners text,
    observed_at timestamptz,
    label_source text,
    created_at timestamptz NOT NULL DEFAULT now(),
    FOREIGN KEY (prediction_id, task) REFERENCES tracing.predictions(prediction_id, task),
    CHECK (useful IS NOT NULL OR observed_pct IS NOT NULL OR observed_owners IS NOT NULL),
    CHECK (
        (task = 'regression' AND observed_owners IS NULL AND
         (observed_pct IS NULL OR observed_pct BETWEEN 0 AND 100))
        OR
        (task = 'classification' AND observed_pct IS NULL AND
         (observed_owners IS NULL OR tracing.valid_owner_range(observed_owners)))
    ),
    CHECK (
        (observed_pct IS NULL AND observed_owners IS NULL AND observed_at IS NULL AND label_source IS NULL)
        OR
        ((observed_pct IS NOT NULL OR observed_owners IS NOT NULL) AND
         observed_at IS NOT NULL AND label_source IS NOT NULL AND length(label_source) > 0)
    )
);
COMMENT ON TABLE tracing.feedbacks IS
    'Un feedback immuable par prediction pour le socle. feedback_id fourni par le client pour reconnaître un retry. useful est subjectif ; observed_* désigne un label observé.';

CREATE INDEX IF NOT EXISTS api_requests_started_idx ON tracing.api_requests(started_at);
CREATE INDEX IF NOT EXISTS api_requests_campaign_time_idx ON tracing.api_requests(campaign_id, started_at);
CREATE INDEX IF NOT EXISTS predictions_model_time_idx ON tracing.predictions(model_id, created_at);
CREATE INDEX IF NOT EXISTS feedbacks_created_idx ON tracing.feedbacks(created_at);

-- Aucun compte applicatif ne peut modifier ou effacer l'historique.
GRANT SELECT, INSERT ON tracing.model_versions, tracing.api_requests,
    tracing.predictions, tracing.feedbacks TO api_writer;
GRANT SELECT ON ALL TABLES IN SCHEMA tracing TO grafana_reader;

COMMIT;
