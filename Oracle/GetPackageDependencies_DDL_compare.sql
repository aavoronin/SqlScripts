/*
================================================================================
СКРИПТ ГЕНЕРАЦИИ КОДА ДЛЯ СРАВНЕНИЯ СТРУКТУРЫ ТАБЛИЦ И ПРЕДСТАВЛЕНИЙ
================================================================================
Этот скрипт анализирует зависимости пакета, извлекает метаданные колонок 
для таблиц и представлений (с учётом фильтрации по маске v_ddl_objects),
и генерирует PL/SQL-блок для запуска на ЦЕЛЕВОМ сервере.
================================================================================
*/

DECLARE
    -- ================= НАСТРОЙКИ ВХОДНЫХ ДАННЫХ =================
    c_pkg_owner CONSTANT VARCHAR2(128) := 'YOUR_SCHEMA';
    c_pkg_name  CONSTANT VARCHAR2(128) := 'YOUR_PACKAGE';

    TYPE t_str_list IS TABLE OF VARCHAR2(128);
    
    v_schemas       t_str_list := t_str_list('SCHEMA1', 'SCHEMA2', 'SCHEMA3');
    
    -- LIKE-маски для определения объектов, метаданные которых нужно собирать
    v_ddl_objects   t_str_list := t_str_list('%TEMP%', 'SCHEMA2.%');
    -- ============================================================

    v_pattern   VARCHAR2(100) := '[a-zA-Z_][a-zA-Z0-9_$#]*(\.[a-zA-Z_][a-zA-Z0-9_$#]*)?';
    v_pos       PLS_INTEGER;
    v_token     VARCHAR2(512);
    v_schema    VARCHAR2(128);
    v_name      VARCHAR2(128);
    v_dummy     PLS_INTEGER;

    TYPE t_checked IS TABLE OF BOOLEAN INDEX BY VARCHAR2(256);
    v_checked   t_checked;

    TYPE t_unqual_checked IS TABLE OF BOOLEAN INDEX BY VARCHAR2(128);
    v_unqual_checked t_unqual_checked;
    v_unqualified    t_str_list := t_str_list();

    -- Типы для хранения метаданных колонок
    TYPE t_col_def IS RECORD (
        col_name       VARCHAR2(128),
        data_type      VARCHAR2(128),
        data_length    NUMBER,
        data_precision NUMBER,
        data_scale     NUMBER
    );
    TYPE t_col_defs IS TABLE OF t_col_def;
    TYPE t_obj_cols IS TABLE OF t_col_defs INDEX BY VARCHAR2(256);
    
    v_obj_metadata t_obj_cols;
    v_processed_objs t_checked;

    FUNCTION is_in_list(p_value IN VARCHAR2, p_list IN t_str_list) RETURN BOOLEAN IS
    BEGIN
        FOR i IN 1 .. p_list.COUNT LOOP
            IF UPPER(p_list(i)) = UPPER(p_value) THEN
                RETURN TRUE;
            END IF;
        END LOOP;
        RETURN FALSE;
    END is_in_list;

    FUNCTION matches_ddl_mask(p_owner IN VARCHAR2, p_name IN VARCHAR2, p_masks IN t_str_list) RETURN BOOLEAN IS
        v_full_name VARCHAR2(256) := UPPER(p_owner) || '.' || UPPER(p_name);
        v_name_upper VARCHAR2(128) := UPPER(p_name);
    BEGIN
        IF p_masks IS NULL OR p_masks.COUNT = 0 THEN
            RETURN FALSE;
        END IF;
        FOR i IN 1 .. p_masks.COUNT LOOP
            IF v_full_name LIKE UPPER(p_masks(i)) 
               OR v_name_upper LIKE UPPER(p_masks(i)) THEN
                RETURN TRUE;
            END IF;
        END LOOP;
        RETURN FALSE;
    END matches_ddl_mask;

    PROCEDURE add_unqualified(p_name IN VARCHAR2) IS
        v_key VARCHAR2(128) := UPPER(p_name);
    BEGIN
        IF NOT v_unqual_checked.EXISTS(v_key) THEN
            v_unqual_checked(v_key) := TRUE;
            v_unqualified.EXTEND;
            v_unqualified(v_unqualified.COUNT) := v_key;
        END IF;
    END add_unqualified;

    PROCEDURE extract_column_metadata(p_owner IN VARCHAR2, p_name IN VARCHAR2) IS
        v_key VARCHAR2(256) := UPPER(p_owner) || '.' || UPPER(p_name);
        v_obj_type VARCHAR2(128);
        v_cols t_col_defs := t_col_defs();
    BEGIN
        IF v_processed_objs.EXISTS(v_key) THEN RETURN; END IF;
        v_processed_objs(v_key) := TRUE;
        
        IF NOT matches_ddl_mask(p_owner, p_name, v_ddl_objects) THEN
            RETURN;
        END IF;

        BEGIN
            SELECT object_type INTO v_obj_type
            FROM all_objects
            WHERE owner = UPPER(p_owner)
              AND object_name = UPPER(p_name)
              AND object_type IN ('TABLE', 'VIEW')
              AND ROWNUM = 1;
        EXCEPTION
            WHEN NO_DATA_FOUND THEN RETURN;
        END;

        FOR c IN (
            SELECT column_name, data_type, data_length, data_precision, data_scale
            FROM all_tab_columns
            WHERE owner = UPPER(p_owner) 
              AND table_name = UPPER(p_name)
            ORDER BY column_id
        ) LOOP
            v_cols.EXTEND;
            v_cols(v_cols.COUNT) := t_col_def(
                c.column_name, 
                c.data_type, 
                c.data_length, 
                c.data_precision, 
                c.data_scale
            );
        END LOOP;

        IF v_cols.COUNT > 0 THEN
            v_obj_metadata(v_key) := v_cols;
        END IF;
    END extract_column_metadata;

    PROCEDURE process_token(p_token IN VARCHAR2) IS
        v_is_qualified BOOLEAN := FALSE;
    BEGIN
        IF INSTR(p_token, '.') > 0 THEN
            v_schema := SUBSTR(p_token, 1, INSTR(p_token, '.') - 1);
            v_name   := SUBSTR(p_token, INSTR(p_token, '.') + 1);
            v_is_qualified := TRUE;
        ELSE
            v_schema := NULL;
            v_name   := p_token;
        END IF;

        BEGIN
            SELECT 1 INTO v_dummy 
            FROM v$reserved_words 
            WHERE keyword = UPPER(v_name) AND ROWNUM = 1;
            RETURN;
        EXCEPTION
            WHEN NO_DATA_FOUND THEN NULL;
            WHEN OTHERS THEN NULL;
        END;

        IF v_is_qualified THEN
            extract_column_metadata(v_schema, v_name);
            FOR i IN 1 .. v_schemas.COUNT LOOP
                extract_column_metadata(v_schemas(i), v_name);
            END LOOP;
        ELSE
            add_unqualified(v_name);
            FOR i IN 1 .. v_schemas.COUNT LOOP
                extract_column_metadata(v_schemas(i), v_name);
            END LOOP;
        END IF;
    END process_token;

    -- Процедура генерации скрипта для целевого сервера
    PROCEDURE generate_target_comparison_script IS
        v_key VARCHAR2(256);
        v_cols t_col_defs;
    BEGIN
        DBMS_OUTPUT.PUT_LINE('================================================================================');
        DBMS_OUTPUT.PUT_LINE('-- СКОПИРУЙТЕ И ВЫПОЛНИТЕ ЭТОТ БЛОК НА ЦЕЛЕВОМ СЕРВЕРЕ');
        DBMS_OUTPUT.PUT_LINE('-- Сравнение структуры таблиц и представлений');
        DBMS_OUTPUT.PUT_LINE('================================================================================');
        DBMS_OUTPUT.PUT_LINE('SET SERVEROUTPUT ON SIZE UNLIMITED;');
        DBMS_OUTPUT.PUT_LINE('DECLARE');
        DBMS_OUTPUT.PUT_LINE('    TYPE t_col_def IS RECORD (');
        DBMS_OUTPUT.PUT_LINE('        col_name       VARCHAR2(128),');
        DBMS_OUTPUT.PUT_LINE('        data_type      VARCHAR2(128),');
        DBMS_OUTPUT.PUT_LINE('        data_length    NUMBER,');
        DBMS_OUTPUT.PUT_LINE('        data_precision NUMBER,');
        DBMS_OUTPUT.PUT_LINE('        data_scale     NUMBER');
        DBMS_OUTPUT.PUT_LINE('    );');
        DBMS_OUTPUT.PUT_LINE('    TYPE t_col_defs IS TABLE OF t_col_def;');
        DBMS_OUTPUT.PUT_LINE('    TYPE t_obj_cols IS TABLE OF t_col_defs INDEX BY VARCHAR2(256);');
        DBMS_OUTPUT.PUT_LINE('    ');
        DBMS_OUTPUT.PUT_LINE('    v_expected t_obj_cols;');
        DBMS_OUTPUT.PUT_LINE('    v_target_cols t_col_defs;');
        DBMS_OUTPUT.PUT_LINE('    v_obj_exists NUMBER;');
        DBMS_OUTPUT.PUT_LINE('    v_key VARCHAR2(256);');
        DBMS_OUTPUT.PUT_LINE('    v_owner VARCHAR2(128);');
        DBMS_OUTPUT.PUT_LINE('    v_name VARCHAR2(128);');
        DBMS_OUTPUT.PUT_LINE('    v_dot_pos NUMBER;');
        DBMS_OUTPUT.PUT_LINE('    v_has_diff BOOLEAN;');
        DBMS_OUTPUT.PUT_LINE('BEGIN');
        
        -- Генерация данных об ожидаемых колонках
        v_key := v_obj_metadata.FIRST;
        WHILE v_key IS NOT NULL LOOP
            v_cols := v_obj_metadata(v_key);
            DBMS_OUTPUT.PUT_LINE('    -- Объект: ' || v_key);
            DBMS_OUTPUT.PUT_LINE('    v_expected(''' || v_key || ''') := t_col_defs(');
            FOR i IN 1 .. v_cols.COUNT LOOP
                DBMS_OUTPUT.PUT_LINE('        t_col_def(''' || v_cols(i).col_name || ''', ''' || 
                                     v_cols(i).data_type || ''', ' || 
                                     NVL(TO_CHAR(v_cols(i).data_length), 'NULL') || ', ' || 
                                     NVL(TO_CHAR(v_cols(i).data_precision), 'NULL') || ', ' || 
                                     NVL(TO_CHAR(v_cols(i).data_scale), 'NULL') || ')' || 
                                     CASE WHEN i < v_cols.COUNT THEN ',' ELSE '' END);
            END LOOP;
            DBMS_OUTPUT.PUT_LINE('    );');
            DBMS_OUTPUT.PUT_LINE('');
            v_key := v_obj_metadata.NEXT(v_key);
        END LOOP;

        -- Генерация логики сравнения
        DBMS_OUTPUT.PUT_LINE('    v_key := v_expected.FIRST;');
        DBMS_OUTPUT.PUT_LINE('    WHILE v_key IS NOT NULL LOOP');
        DBMS_OUTPUT.PUT_LINE('        v_dot_pos := INSTR(v_key, ''.'');');
        DBMS_OUTPUT.PUT_LINE('        v_owner := SUBSTR(v_key, 1, v_dot_pos - 1);');
        DBMS_OUTPUT.PUT_LINE('        v_name := SUBSTR(v_key, v_dot_pos + 1);');
        DBMS_OUTPUT.PUT_LINE('        v_has_diff := FALSE;');
        DBMS_OUTPUT.PUT_LINE('');
        DBMS_OUTPUT.PUT_LINE('        -- 1) Проверка наличия объекта');
        DBMS_OUTPUT.PUT_LINE('        SELECT COUNT(*) INTO v_obj_exists');
        DBMS_OUTPUT.PUT_LINE('        FROM all_objects');
        DBMS_OUTPUT.PUT_LINE('        WHERE owner = v_owner');
        DBMS_OUTPUT.PUT_LINE('          AND object_name = v_name');
        DBMS_OUTPUT.PUT_LINE('          AND object_type IN (''TABLE'', ''VIEW'');');
        DBMS_OUTPUT.PUT_LINE('');
        DBMS_OUTPUT.PUT_LINE('        IF v_obj_exists = 0 THEN');
        DBMS_OUTPUT.PUT_LINE('            DBMS_OUTPUT.PUT_LINE(''1) Table/View is not present: '' || v_key);');
        DBMS_OUTPUT.PUT_LINE('            v_key := v_expected.NEXT(v_key);');
        DBMS_OUTPUT.PUT_LINE('            CONTINUE;');
        DBMS_OUTPUT.PUT_LINE('        END IF;');
        DBMS_OUTPUT.PUT_LINE('');
        DBMS_OUTPUT.PUT_LINE('        -- Получение фактических колонок с целевого сервера');
        DBMS_OUTPUT.PUT_LINE('        SELECT column_name, data_type, data_length, data_precision, data_scale');
        DBMS_OUTPUT.PUT_LINE('        BULK COLLECT INTO v_target_cols');
        DBMS_OUTPUT.PUT_LINE('        FROM all_tab_columns');
        DBMS_OUTPUT.PUT_LINE('        WHERE owner = v_owner AND table_name = v_name');
        DBMS_OUTPUT.PUT_LINE('        ORDER BY column_id;');
        DBMS_OUTPUT.PUT_LINE('');
        DBMS_OUTPUT.PUT_LINE('        -- 5) Проверка разного количества колонок');
        DBMS_OUTPUT.PUT_LINE('        IF v_expected(v_key).COUNT != v_target_cols.COUNT THEN');
        DBMS_OUTPUT.PUT_LINE('            DBMS_OUTPUT.PUT_LINE(''5) Different number of columns in '' || v_key || ');
        DBMS_OUTPUT.PUT_LINE('                                 '' (Expected: '' || v_expected(v_key).COUNT || '');');
        DBMS_OUTPUT.PUT_LINE('                                 '', Found: '' || v_target_cols.COUNT || '')'');');
        DBMS_OUTPUT.PUT_LINE('            v_has_diff := TRUE;');
        DBMS_OUTPUT.PUT_LINE('        END IF;');
        DBMS_OUTPUT.PUT_LINE('');
        DBMS_OUTPUT.PUT_LINE('        -- Проверка отсутствующих и отличающихся колонок');
        DBMS_OUTPUT.PUT_LINE('        FOR i IN 1 .. v_expected(v_key).COUNT LOOP');
        DBMS_OUTPUT.PUT_LINE('            DECLARE');
        DBMS_OUTPUT.PUT_LINE('                v_found BOOLEAN := FALSE;');
        DBMS_OUTPUT.PUT_LINE('            BEGIN');
        DBMS_OUTPUT.PUT_LINE('                FOR j IN 1 .. v_target_cols.COUNT LOOP');
        DBMS_OUTPUT.PUT_LINE('                    IF v_target_cols(j).col_name = v_expected(v_key)(i).col_name THEN');
        DBMS_OUTPUT.PUT_LINE('                        v_found := TRUE;');
        DBMS_OUTPUT.PUT_LINE('                        -- 4) Проверка отличий в типе или атрибутах');
        DBMS_OUTPUT.PUT_LINE('                        IF v_target_cols(j).data_type != v_expected(v_key)(i).data_type OR');
        DBMS_OUTPUT.PUT_LINE('                           NVL(v_target_cols(j).data_length, -1) != NVL(v_expected(v_key)(i).data_length, -1) OR');
        DBMS_OUTPUT.PUT_LINE('                           NVL(v_target_cols(j).data_precision, -1) != NVL(v_expected(v_key)(i).data_precision, -1) OR');
        DBMS_OUTPUT.PUT_LINE('                           NVL(v_target_cols(j).data_scale, -1) != NVL(v_expected(v_key)(i).data_scale, -1) THEN');
        DBMS_OUTPUT.PUT_LINE('                            DBMS_OUTPUT.PUT_LINE(''4) Different column in '' || v_key || '': '' || v_expected(v_key)(i).col_name ||');
        DBMS_OUTPUT.PUT_LINE('                                         '' (Expected: '' || v_expected(v_key)(i).data_type ||');
        DBMS_OUTPUT.PUT_LINE('                                         ''['' || NVL(TO_CHAR(v_expected(v_key)(i).data_length), ''*'') ||');
        DBMS_OUTPUT.PUT_LINE('                                         '','' || NVL(TO_CHAR(v_expected(v_key)(i).data_precision), ''*'') ||');
        DBMS_OUTPUT.PUT_LINE('                                         '','' || NVL(TO_CHAR(v_expected(v_key)(i).data_scale), ''*'') || '']'');');
        DBMS_OUTPUT.PUT_LINE('                                         '', Found: '' || v_target_cols(j).data_type ||');
        DBMS_OUTPUT.PUT_LINE('                                         ''['' || NVL(TO_CHAR(v_target_cols(j).data_length), ''*'') ||');
        DBMS_OUTPUT.PUT_LINE('                                         '','' || NVL(TO_CHAR(v_target_cols(j).data_precision), ''*'') ||');
        DBMS_OUTPUT.PUT_LINE('                                         '','' || NVL(TO_CHAR(v_target_cols(j).data_scale), ''*'') || '']'');');
        DBMS_OUTPUT.PUT_LINE('                            v_has_diff := TRUE;');
        DBMS_OUTPUT.PUT_LINE('                        END IF;');
        DBMS_OUTPUT.PUT_LINE('                        EXIT;');
        DBMS_OUTPUT.PUT_LINE('                    END IF;');
        DBMS_OUTPUT.PUT_LINE('                END LOOP;');
        DBMS_OUTPUT.PUT_LINE('');
        DBMS_OUTPUT.PUT_LINE('                -- 2) Проверка отсутствующей колонки');
        DBMS_OUTPUT.PUT_LINE('                IF NOT v_found THEN');
        DBMS_OUTPUT.PUT_LINE('                    DBMS_OUTPUT.PUT_LINE(''2) Missing column in '' || v_key || '': '' || v_expected(v_key)(i).col_name ||');
        DBMS_OUTPUT.PUT_LINE('                                 '' ('' || v_expected(v_key)(i).data_type || '')'');');
        DBMS_OUTPUT.PUT_LINE('                    v_has_diff := TRUE;');
        DBMS_OUTPUT.PUT_LINE('                END IF;');
        DBMS_OUTPUT.PUT_LINE('            END;');
        DBMS_OUTPUT.PUT_LINE('        END LOOP;');
        DBMS_OUTPUT.PUT_LINE('');
        DBMS_OUTPUT.PUT_LINE('        -- 3) Проверка лишних колонок (есть на целевом, но нет в оригинале)');
        DBMS_OUTPUT.PUT_LINE('        FOR j IN 1 .. v_target_cols.COUNT LOOP');
        DBMS_OUTPUT.PUT_LINE('            DECLARE');
        DBMS_OUTPUT.PUT_LINE('                v_found BOOLEAN := FALSE;');
        DBMS_OUTPUT.PUT_LINE('            BEGIN');
        DBMS_OUTPUT.PUT_LINE('                FOR i IN 1 .. v_expected(v_key).COUNT LOOP');
        DBMS_OUTPUT.PUT_LINE('                    IF v_target_cols(j).col_name = v_expected(v_key)(i).col_name THEN');
        DBMS_OUTPUT.PUT_LINE('                        v_found := TRUE;');
        DBMS_OUTPUT.PUT_LINE('                        EXIT;');
        DBMS_OUTPUT.PUT_LINE('                    END IF;');
        DBMS_OUTPUT.PUT_LINE('                END LOOP;');
        DBMS_OUTPUT.PUT_LINE('');
        DBMS_OUTPUT.PUT_LINE('                IF NOT v_found THEN');
        DBMS_OUTPUT.PUT_LINE('                    DBMS_OUTPUT.PUT_LINE(''3) Extra column in '' || v_key || '': '' || v_target_cols(j).col_name ||');
        DBMS_OUTPUT.PUT_LINE('                                 '' ('' || v_target_cols(j).data_type || '') (not on original server)'');');
        DBMS_OUTPUT.PUT_LINE('                    v_has_diff := TRUE;');
        DBMS_OUTPUT.PUT_LINE('                END IF;');
        DBMS_OUTPUT.PUT_LINE('            END;');
        DBMS_OUTPUT.PUT_LINE('        END LOOP;');
        DBMS_OUTPUT.PUT_LINE('');
        DBMS_OUTPUT.PUT_LINE('        -- 6) Если отличий не найдено');
        DBMS_OUTPUT.PUT_LINE('        IF NOT v_has_diff THEN');
        DBMS_OUTPUT.PUT_LINE('            DBMS_OUTPUT.PUT_LINE(''6) Object '' || v_key || '' has no differences.'');');
        DBMS_OUTPUT.PUT_LINE('        END IF;');
        DBMS_OUTPUT.PUT_LINE('');
        DBMS_OUTPUT.PUT_LINE('        DBMS_OUTPUT.PUT_LINE(''--------------------------------------------------'');');
        DBMS_OUTPUT.PUT_LINE('        v_key := v_expected.NEXT(v_key);');
        DBMS_OUTPUT.PUT_LINE('    END LOOP;');
        DBMS_OUTPUT.PUT_LINE('END;');
        DBMS_OUTPUT.PUT_LINE('/');
        DBMS_OUTPUT.PUT_LINE('================================================================================');
    END generate_target_comparison_script;

BEGIN
    DBMS_OUTPUT.PUT_LINE('-- Начало анализа пакета ' || c_pkg_owner || '.' || c_pkg_name);
    DBMS_OUTPUT.PUT_LINE('-- Фильтрация по маске v_ddl_objects применяется при сборе метаданных');
    DBMS_OUTPUT.PUT_LINE('');

    FOR src IN (
        SELECT text 
        FROM all_source 
        WHERE owner = UPPER(c_pkg_owner) 
          AND name = UPPER(c_pkg_name) 
          AND type = 'PACKAGE BODY'
        ORDER BY line
    ) LOOP
        IF src.text IS NOT NULL AND LENGTH(src.text) > 0 THEN
            v_pos := 1;
            LOOP
                v_pos := REGEXP_INSTR(src.text, v_pattern, v_pos);
                EXIT WHEN v_pos = 0;
                
                v_token := REGEXP_SUBSTR(src.text, v_pattern, v_pos);
                v_pos := v_pos + LENGTH(v_token);
                
                process_token(v_token);
            END LOOP;
        END IF;
    END LOOP;

    IF v_obj_metadata.COUNT > 0 THEN
        DBMS_OUTPUT.PUT_LINE('-- Найдено объектов, удовлетворяющих маске: ' || v_obj_metadata.COUNT);
        DBMS_OUTPUT.PUT_LINE('');
        generate_target_comparison_script;
    ELSE
        DBMS_OUTPUT.PUT_LINE('-- Зависимые таблицы или представления, удовлетворяющие маске v_ddl_objects, не найдены.');
    END IF;

    DBMS_OUTPUT.PUT_LINE('');
    DBMS_OUTPUT.PUT_LINE('-- Анализ завершен.');
END;
/