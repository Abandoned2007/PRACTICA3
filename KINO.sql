-- 3.1. ПЕРВИЧНЫЙ КЛЮЧ + SEQUENCE

-- Проверяем: уникален ли data.general.id
SELECT "data.general.id", COUNT(*)
FROM cinema_registry.cinema_places
GROUP BY "data.general.id"
HAVING COUNT(*) > 1;

-- Создаём sequence для суррогатного PK
CREATE SEQUENCE cinema_registry.cinema_places_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;

-- Добавляем суррогатный столбец id
ALTER TABLE cinema_registry.cinema_places
    ADD COLUMN id BIGINT;

-- Заполняем id из sequence
UPDATE cinema_registry.cinema_places
SET id = nextval('cinema_registry.cinema_places_id_seq');

-- Делаем id обязательным и назначаем PK
ALTER TABLE cinema_registry.cinema_places
    ALTER COLUMN id SET NOT NULL;

ALTER TABLE cinema_registry.cinema_places
    ADD CONSTRAINT cinema_places_pkey PRIMARY KEY (id);

-- Привязываем sequence к колонке
ALTER SEQUENCE cinema_registry.cinema_places_id_seq
    OWNED BY cinema_registry.cinema_places.id;

-- Автозаполнение id для будущих вставок
ALTER TABLE cinema_registry.cinema_places
    ALTER COLUMN id SET DEFAULT nextval('cinema_registry.cinema_places_id_seq');

-- Проверка
SELECT COUNT(*) AS total,
       COUNT(id) AS with_id,
       COUNT(DISTINCT id) AS distinct_id
FROM cinema_registry.cinema_places;


-- 3.2. ОГРАНИЧЕНИЯ NOT NULL И UNIQUE

-- Проверяем кандидатов на NOT NULL
SELECT
    COUNT(*) FILTER (WHERE "data.general.name" IS NULL) AS null_name,
    COUNT(*) FILTER (WHERE "data.general.address.fullAddress" IS NULL) AS null_addr
FROM cinema_registry.cinema_places;

-- NOT NULL: название кинотеатра обязательно
ALTER TABLE cinema_registry.cinema_places
    ALTER COLUMN "data.general.name" SET NOT NULL;

-- NOT NULL: полный адрес обязателен
ALTER TABLE cinema_registry.cinema_places
    ALTER COLUMN "data.general.address.fullAddress" SET NOT NULL;

-- Проверяем, что data.general.id уникален
SELECT COUNT(*) AS total,
       COUNT(DISTINCT "data.general.id") AS distinct_ids
FROM cinema_registry.cinema_places;

-- UNIQUE на data.general.id (name содержит дубли)
ALTER TABLE cinema_registry.cinema_places
    ADD CONSTRAINT uq_cinema_general_id
    UNIQUE ("data.general.id");

-- Проверка ограничений
SELECT conname, contype
FROM pg_constraint
WHERE conrelid = 'cinema_registry.cinema_places'::regclass
  AND contype IN ('p', 'u');


-- 3.3.1. УДАЛЕНИЕ ВСЕГО, КРОМЕ ВЫБРАННОГО РЕГИОНА

-- Смотрим, какие регионы есть в данных
SELECT DISTINCT "data.general.locale.name"
FROM cinema_registry.cinema_places
LIMIT 50;

-- Удаляем всё, что не Тверская область
DELETE FROM cinema_registry.cinema_places
WHERE "data.general.locale.name" NOT LIKE '%Тверь%'
   OR "data.general.locale.name" IS NULL;

-- Проверка
SELECT COUNT(*) FROM cinema_registry.cinema_places;
SELECT DISTINCT "data.general.locale.name"
FROM cinema_registry.cinema_places;


-- 3.3.2. POSTGIS + КОЛОНКА geom

-- Устанавливаем расширение PostGIS
CREATE EXTENSION postgis SCHEMA public;

-- Проверяем версию
SELECT PostGIS_Version();

-- Добавляем колонку geom
ALTER TABLE cinema_registry.cinema_places
    ADD COLUMN geom geometry(Point, 4326);


-- 3.3.3 – 3.3.4. ЗАПОЛНЕНИЕ geom ИЗ JSONB

-- Смотрим пример mapPosition
SELECT "data.general.address.mapPosition"
FROM cinema_registry.cinema_places
WHERE "data.general.address.mapPosition" IS NOT NULL
LIMIT 5;

-- Заполняем geom через ST_GeomFromGeoJSON
UPDATE cinema_registry.cinema_places
SET geom = ST_GeomFromGeoJSON("data.general.address.mapPosition"::text)
WHERE "data.general.address.mapPosition" IS NOT NULL
  AND "data.general.address.mapPosition"::text <> ''
  AND "data.general.address.mapPosition"::text <> 'null';

-- Проверка: сколько строк получили геометрию
SELECT
    COUNT(*) AS total,
    COUNT(geom) AS with_geom,
    COUNT(*) - COUNT(geom) AS without_geom
FROM cinema_registry.cinema_places;

-- Проверка SRID
SELECT ST_SRID(geom), COUNT(*)
FROM cinema_registry.cinema_places
WHERE geom IS NOT NULL
GROUP BY 1;


-- 3.3.5. ТАБЛИЦА tags

CREATE TABLE cinema_registry.tags (
    id          BIGSERIAL PRIMARY KEY,          -- PK + sequence
    name        VARCHAR(255) NOT NULL UNIQUE,   -- название тега
    created_at  TIMESTAMPTZ DEFAULT NOW(),      -- дата добавления
    description TEXT                            -- описание
);

-- Проверка
SELECT * FROM cinema_registry.tags;


-- 3.3.6. ЗАПОЛНЕНИЕ tags ИЗ JSONB-МАССИВА

-- Проверяем тип данных в data.general.tags
SELECT jsonb_typeof("data.general.tags"), COUNT(*)
FROM cinema_registry.cinema_places
GROUP BY 1;

-- Вставляем уникальные теги (в файле теги — объекты {id, name, sysName})
INSERT INTO cinema_registry.tags (name)
SELECT DISTINCT elem->>'name'
FROM cinema_registry.cinema_places c
CROSS JOIN LATERAL jsonb_array_elements(c."data.general.tags") AS elem
WHERE c."data.general.tags" IS NOT NULL
  AND jsonb_typeof(c."data.general.tags") = 'array'
  AND elem->>'name' IS NOT NULL
ON CONFLICT (name) DO NOTHING;

-- Проверка
SELECT COUNT(*) AS total_tags FROM cinema_registry.tags;
SELECT * FROM cinema_registry.tags LIMIT 20;


-- 3.3.7. M2M-ТАБЛИЦА

CREATE TABLE cinema_registry.m2m_cinema_places_tags (
    culture_place_id BIGINT NOT NULL
        REFERENCES cinema_registry.cinema_places(id) ON DELETE CASCADE,
    tag_id           BIGINT NOT NULL
        REFERENCES cinema_registry.tags(id) ON DELETE CASCADE,
    PRIMARY KEY (culture_place_id, tag_id)
);

-- Заполняем связями
INSERT INTO cinema_registry.m2m_cinema_places_tags (culture_place_id, tag_id)
SELECT DISTINCT
    c.id,
    t.id
FROM cinema_registry.cinema_places c
CROSS JOIN LATERAL jsonb_array_elements(c."data.general.tags") AS elem
JOIN cinema_registry.tags t ON t.name = elem->>'name'
WHERE c."data.general.tags" IS NOT NULL
  AND jsonb_typeof(c."data.general.tags") = 'array'
ON CONFLICT DO NOTHING;

-- Проверка
SELECT COUNT(*) AS total_links
FROM cinema_registry.m2m_cinema_places_tags;

-- Сколько тегов у каждого кинотеатра (топ-20)
SELECT c.id, c."data.general.name", COUNT(m.tag_id) AS tag_count
FROM cinema_registry.cinema_places c
LEFT JOIN cinema_registry.m2m_cinema_places_tags m
       ON m.culture_place_id = c.id
GROUP BY c.id, c."data.general.name"
ORDER BY tag_count DESC
LIMIT 20;


-- 3.3.8. ИНДЕКСЫ НА M2M-ТАБЛИЦЕ

CREATE INDEX idx_m2m_culture_place_id
    ON cinema_registry.m2m_cinema_places_tags (culture_place_id);

CREATE INDEX idx_m2m_tag_id
    ON cinema_registry.m2m_cinema_places_tags (tag_id);

-- Проверка индексов
SELECT indexname, indexdef
FROM pg_indexes
WHERE schemaname = 'cinema_registry'
  AND tablename = 'm2m_cinema_places_tags';
