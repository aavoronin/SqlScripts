DECLARE
    -- ================= НАСТРОЙКИ ВХОДНЫХ ДАННЫХ =================
    c_pkg_owner CONSTANT VARCHAR2(128) := 'YOUR_SCHEMA';
    c_pkg_name  CONSTANT VARCHAR2(128) := 'YOUR_PACKAGE';

    TYPE t_str_list IS TABLE OF VARCHAR2(128);
    TYPE t_clob_list IS TABLE OF CLOB;

    v_schemas       t_str_list := t_str_list('SCHEMA1', 'SCHEMA2', 'SCHEMA3');
    v_grantees      t_str_list := t_str_list('USER_A', 'USER_B', 'ROLE_C');
    v_ddl_objects   t_str_list := t_str_list('%TEMP%', 'SCHEMA2.%');

    -- Разрешённые привилегии для отслеживания грантов
    v_allowed_privs t_str_list := t_str_list('SELECT', 'INSERT', 'UPDATE', 'DELETE', 'EXECUTE', 'MERGE');

    -- Объекты, гранты по которым не выводить (исключаются только из выдачи грантов, не из остальной логики)
    v_exclude_from_grants t_str_list := t_str_list('EXCLUDED_OBJ1', 'EXCLUDED_OBJ2');

    TYPE t_removal_rec IS RECORD (
        pattern     VARCHAR2(4000),
        replacement VARCHAR2(4000)
    );
    TYPE t_removal_list IS TABLE OF t_removal_rec;
    v_ddl_removals  t_removal_list := t_removal_list();
    -- ============================================================

    v_pattern   VARCHAR2(100) := '[a-zA-Z_][a-zA-Z0-9_$#]*(\.[a-zA-Z_][a-zA-Z0-9_$#]*)?';
    v_pos       PLS_INTEGER;
    v_token     VARCHAR2(512);
    v_schema    VARCHAR2(128);
    v_name      VARCHAR2(128);
    v_dummy     PLS_INTEGER;

    TYPE t_checked IS TABLE OF BOOLEAN INDEX BY VARCHAR2(256);
    v_checked   t_checked;

    TYPE t_obj_rec IS RECORD (
        owner     VARCHAR2(128),
        name      VARCHAR2(128),
        obj_type  VARCHAR2(128),
        col_cnt   NUMBER
    );
    TYPE t_obj_list IS TABLE OF t_obj_rec;
    v_objects t_obj_list := t_obj_list();

    TYPE t_unqual_checked IS TABLE OF BOOLEAN INDEX BY VARCHAR2(128);
    v_unqual_checked t_unqual_checked;
    v_unqualified    t_str_list := t_str_list();

    TYPE t_missing_grant IS RECORD (
        privilege VARCHAR2(128),
        obj_name  VARCHAR2(128),
        grantee   VARCHAR2(128),
        grantable VARCHAR2(3)
    );
    TYPE t_missing_grant_list IS TABLE OF t_missing_grant;

    TYPE t_missing_by_schema IS TABLE OF t_missing_grant_list INDEX BY VARCHAR2(128);

    FUNCTION is_in_list(p_value IN VARCHAR2, p_list IN t_str_list) RETURN BOOLEAN IS
    BEGIN
        FOR i IN 1 .. p_list.COUNT LOOP
            IF UPPER(p_list(i)) = UPPER(p_value) THEN
                RETURN TRUE;
            END IF;
        END LOOP;
        RETURN FALSE;
    END is_in_list;

    PROCEDURE add_unqualified(p_name IN VARCHAR2) IS
        v_key VARCHAR2(128) := UPPER(p_name);
    BEGIN
        IF NOT v_unqual_checked.EXISTS(v_key) THEN
            v_unqual_checked(v_key) := TRUE;
            v_unqualified.EXTEND;
            v_unqualified(v_unqualified.COUNT) := v_key;
        END IF;
    END add_unqualified;

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

    PROCEDURE apply_removals(p_ddl IN OUT CLOB, p_rules IN t_removal_list) IS
        v_start_word VARCHAR2(4000);
        v_end_word   VARCHAR2(4000);
        v_pipe_pos   PLS_INTEGER;
        v_start_pos  INTEGER;
        v_end_pos    INTEGER;
        v_replace_len INTEGER;
        v_section_len INTEGER;
        v_tmp_clob   CLOB;
        v_after_pos  INTEGER;
        v_after_len  INTEGER;
        v_chunk_size CONSTANT INTEGER := 32000;
        v_copy_offset INTEGER;
        v_dest_offset INTEGER;
        v_remaining  INTEGER;
        v_chunk_len  INTEGER;
    BEGIN
        IF p_rules IS NULL OR p_rules.COUNT = 0 THEN
            RETURN;
        END IF;

        FOR r IN 1 .. p_rules.COUNT LOOP
            v_pipe_pos := INSTR(p_rules(r).pattern, '|');
            IF v_pipe_pos = 0 THEN
                CONTINUE;
            END IF;

            v_start_word := SUBSTR(p_rules(r).pattern, 1, v_pipe_pos - 1);
            v_end_word   := SUBSTR(p_rules(r).pattern, v_pipe_pos + 1);

            IF v_start_word IS NULL OR v_end_word IS NULL THEN
                CONTINUE;
            END IF;

            v_start_pos := DBMS_LOB.INSTR(p_ddl, v_start_word, 1, 1);

            WHILE v_start_pos > 0 LOOP
                v_end_pos := DBMS_LOB.INSTR(p_ddl, v_end_word, v_start_pos + LENGTH(v_start_word), 1);

                IF v_end_pos > 0 THEN
                    v_section_len := (v_end_pos - v_start_pos) + LENGTH(v_end_word);
                    v_replace_len := NVL(LENGTH(p_rules(r).replacement), 0);

                    DBMS_LOB.CREATETEMPORARY(v_tmp_clob, TRUE);

                    v_copy_offset := 1;
                    v_dest_offset := 1;
                    v_remaining := v_start_pos - 1;
                    WHILE v_remaining > 0 LOOP
                        v_chunk_len := LEAST(v_chunk_size, v_remaining);
                        DBMS_LOB.COPY(v_tmp_clob, p_ddl, v_chunk_len, v_dest_offset, v_copy_offset);
                        v_copy_offset := v_copy_offset + v_chunk_len;
                        v_dest_offset := v_dest_offset + v_chunk_len;
                        v_remaining := v_remaining - v_chunk_len;
                    END LOOP;

                    IF v_replace_len > 0 THEN
                        DBMS_LOB.WRITEAPPEND(v_tmp_clob, v_replace_len, p_rules(r).replacement);
                    END IF;

                    v_after_pos := v_start_pos + v_section_len;
                    v_after_len := DBMS_LOB.GETLENGTH(p_ddl) - v_after_pos + 1;
                    v_copy_offset := v_after_pos;
                    v_dest_offset := DBMS_LOB.GETLENGTH(v_tmp_clob) + 1;
                    v_remaining := v_after_len;
                    WHILE v_remaining > 0 LOOP
                        v_chunk_len := LEAST(v_chunk_size, v_remaining);
                        DBMS_LOB.COPY(v_tmp_clob, p_ddl, v_chunk_len, v_dest_offset, v_copy_offset);
                        v_copy_offset := v_copy_offset + v_chunk_len;
                        v_dest_offset := v_dest_offset + v_chunk_len;
                        v_remaining := v_remaining - v_chunk_len;
                    END LOOP;

                    DBMS_LOB.TRIM(p_ddl, 0);

                    IF DBMS_LOB.GETLENGTH(v_tmp_clob) > 0 THEN
                        v_copy_offset := 1;
                        v_dest_offset := 1;
                        v_remaining := DBMS_LOB.GETLENGTH(v_tmp_clob);
                        WHILE v_remaining > 0 LOOP
                            v_chunk_len := LEAST(v_chunk_size, v_remaining);
                            DBMS_LOB.COPY(p_ddl, v_tmp_clob, v_chunk_len, v_dest_offset, v_copy_offset);
                            v_copy_offset := v_copy_offset + v_chunk_len;
                            v_dest_offset := v_dest_offset + v_chunk_len;
                            v_remaining := v_remaining - v_chunk_len;
                        END LOOP;
                    END IF;
                    DBMS_LOB.FREETEMPORARY(v_tmp_clob);

                    v_start_pos := DBMS_LOB.INSTR(p_ddl, v_start_word, v_start_pos + v_replace_len, 1);
                ELSE
                    EXIT;
                END IF;
            END LOOP;
        END LOOP;
    EXCEPTION
        WHEN OTHERS THEN
            DBMS_OUTPUT.PUT_LINE('-- Ошибка применения замен в DDL: ' || SQLERRM);
    END apply_removals;

    FUNCTION replace_schema_in_ddl(p_ddl IN CLOB, p_schema IN VARCHAR2) RETURN CLOB IS
        v_result CLOB;
        v_schema_upper VARCHAR2(128) := UPPER(p_schema);
        v_replacement VARCHAR2(20) := '<schema>';
        v_pos INTEGER := 1;
        v_next_pos INTEGER;
        v_chunk_len INTEGER;
    BEGIN
        DBMS_LOB.CREATETEMPORARY(v_result, TRUE);

        LOOP
            v_next_pos := DBMS_LOB.INSTR(p_ddl, v_schema_upper, v_pos, 1);

            IF v_next_pos = 0 THEN
                v_chunk_len := DBMS_LOB.GETLENGTH(p_ddl) - v_pos + 1;
                IF v_chunk_len > 0 THEN
                    DBMS_LOB.COPY(v_result, p_ddl, v_chunk_len, DBMS_LOB.GETLENGTH(v_result) + 1, v_pos);
                END IF;
                EXIT;
            END IF;

            v_chunk_len := v_next_pos - v_pos;
            IF v_chunk_len > 0 THEN
                DBMS_LOB.COPY(v_result, p_ddl, v_chunk_len, DBMS_LOB.GETLENGTH(v_result) + 1, v_pos);
            END IF;

            DBMS_LOB.WRITEAPPEND(v_result, LENGTH(v_replacement), v_replacement);
            v_pos := v_next_pos + LENGTH(v_schema_upper);
        END LOOP;

        RETURN v_result;
    END replace_schema_in_ddl;

    FUNCTION normalize_whitespace(p_src IN CLOB) RETURN CLOB IS
        v_result CLOB;
        v_chunk VARCHAR2(32000);
        v_offset INTEGER := 1;
        v_len INTEGER;
        v_chunk_len INTEGER;
    BEGIN
        DBMS_LOB.CREATETEMPORARY(v_result, TRUE);
        v_len := DBMS_LOB.GETLENGTH(p_src);

        WHILE v_offset <= v_len LOOP
            v_chunk_len := LEAST(32000, v_len - v_offset + 1);
            v_chunk := DBMS_LOB.SUBSTR(p_src, v_chunk_len, v_offset);
            v_chunk := REGEXP_REPLACE(v_chunk, '[[:space:]]+', ' ');
            DBMS_LOB.WRITEAPPEND(v_result, LENGTH(v_chunk), v_chunk);
            v_offset := v_offset + v_chunk_len;
        END LOOP;

        RETURN v_result;
    END normalize_whitespace;

    FUNCTION normalize_ddl_for_compare(p_ddl IN CLOB, p_schema IN VARCHAR2) RETURN CLOB IS
        v_result CLOB;
    BEGIN
        IF p_ddl IS NULL THEN
            RETURN NULL;
        END IF;

        v_result := replace_schema_in_ddl(p_ddl, p_schema);
        apply_removals(v_result, v_ddl_removals);
        v_result := normalize_whitespace(v_result);

        RETURN v_result;
    END normalize_ddl_for_compare;

    PROCEDURE make_create_or_replace(p_ddl IN OUT CLOB, p_obj_type IN VARCHAR2) IS
        v_create_pos INTEGER;
        v_or_pos     INTEGER;
        v_tmp        CLOB;
        v_chunk_size CONSTANT INTEGER := 32000;
        v_copy_offset INTEGER;
        v_dest_offset INTEGER;
        v_remaining  INTEGER;
        v_chunk_len  INTEGER;
    BEGIN
        IF p_obj_type NOT IN ('VIEW', 'FUNCTION') THEN
            RETURN;
        END IF;

        v_create_pos := DBMS_LOB.INSTR(p_ddl, 'CREATE ');
        IF v_create_pos = 0 THEN
            RETURN;
        END IF;

        v_or_pos := DBMS_LOB.INSTR(p_ddl, 'OR REPLACE', v_create_pos);
        IF v_or_pos > 0 AND v_or_pos < v_create_pos + 20 THEN
            RETURN;
        END IF;

        DBMS_LOB.CREATETEMPORARY(v_tmp, TRUE);

        IF v_create_pos > 1 THEN
            v_copy_offset := 1;
            v_dest_offset := 1;
            v_remaining := v_create_pos - 1;
            WHILE v_remaining > 0 LOOP
                v_chunk_len := LEAST(v_chunk_size, v_remaining);
                DBMS_LOB.COPY(v_tmp, p_ddl, v_chunk_len, v_dest_offset, v_copy_offset);
                v_copy_offset := v_copy_offset + v_chunk_len;
                v_dest_offset := v_dest_offset + v_chunk_len;
                v_remaining := v_remaining - v_chunk_len;
            END LOOP;
        END IF;

        DBMS_LOB.WRITEAPPEND(v_tmp, 17, 'CREATE OR REPLACE ');

        v_copy_offset := v_create_pos + 7;
        v_dest_offset := DBMS_LOB.GETLENGTH(v_tmp) + 1;
        v_remaining := DBMS_LOB.GETLENGTH(p_ddl) - v_create_pos - 7 + 1;
        WHILE v_remaining > 0 LOOP
            v_chunk_len := LEAST(v_chunk_size, v_remaining);
            DBMS_LOB.COPY(v_tmp, p_ddl, v_chunk_len, v_dest_offset, v_copy_offset);
            v_copy_offset := v_copy_offset + v_chunk_len;
            v_dest_offset := v_dest_offset + v_chunk_len;
            v_remaining := v_remaining - v_chunk_len;
        END LOOP;

        DBMS_LOB.TRIM(p_ddl, 0);
        IF DBMS_LOB.GETLENGTH(v_tmp) > 0 THEN
            v_copy_offset := 1;
            v_dest_offset := 1;
            v_remaining := DBMS_LOB.GETLENGTH(v_tmp);
            WHILE v_remaining > 0 LOOP
                v_chunk_len := LEAST(v_chunk_size, v_remaining);
                DBMS_LOB.COPY(p_ddl, v_tmp, v_chunk_len, v_dest_offset, v_copy_offset);
                v_copy_offset := v_copy_offset + v_chunk_len;
                v_dest_offset := v_dest_offset + v_chunk_len;
                v_remaining := v_remaining - v_chunk_len;
            END LOOP;
        END IF;
        DBMS_LOB.FREETEMPORARY(v_tmp);
    END make_create_or_replace;

    PROCEDURE escape_quotes(p_src IN CLOB, p_dst IN OUT CLOB) IS
        v_pos       INTEGER := 1;
        v_next_pos  INTEGER;
        v_chunk_len INTEGER;
    BEGIN
        DBMS_LOB.CREATETEMPORARY(p_dst, TRUE);

        LOOP
            v_next_pos := DBMS_LOB.INSTR(p_src, '''', v_pos, 1);

            IF v_next_pos = 0 THEN
                v_chunk_len := DBMS_LOB.GETLENGTH(p_src) - v_pos + 1;
                IF v_chunk_len > 0 THEN
                    DBMS_LOB.COPY(p_dst, p_src, v_chunk_len, DBMS_LOB.GETLENGTH(p_dst) + 1, v_pos);
                END IF;
                EXIT;
            END IF;

            v_chunk_len := v_next_pos - v_pos;
            IF v_chunk_len > 0 THEN
                DBMS_LOB.COPY(p_dst, p_src, v_chunk_len, DBMS_LOB.GETLENGTH(p_dst) + 1, v_pos);
            END IF;

            DBMS_LOB.WRITEAPPEND(p_dst, 2, '''''');

            v_pos := v_next_pos + 1;
        END LOOP;
    END escape_quotes;

    PROCEDURE print_escaped_clob(p_clob IN CLOB) IS
        v_offset INTEGER := 1;
        v_chunk  VARCHAR2(32767);
        v_len    INTEGER;
    BEGIN
        v_len := DBMS_LOB.GETLENGTH(p_clob);
        WHILE v_offset <= v_len LOOP
            v_chunk := DBMS_LOB.SUBSTR(p_clob, 32767, v_offset);
            DBMS_OUTPUT.PUT(v_chunk);
            v_offset := v_offset + 32767;
        END LOOP;
    END print_escaped_clob;

    PROCEDURE output_ddl_for_object(p_owner IN VARCHAR2, p_name IN VARCHAR2, p_obj_type IN VARCHAR2, p_print IN BOOLEAN DEFAULT TRUE) IS
        v_ddl       CLOB;
        v_escaped   CLOB;
        v_len       INTEGER;
        v_full_name VARCHAR2(256) := UPPER(p_owner) || '.' || UPPER(p_name);
    BEGIN
        v_ddl := DBMS_METADATA.GET_DDL(
            object_type => p_obj_type,
            name        => UPPER(p_name),
            schema      => UPPER(p_owner)
        );

        apply_removals(v_ddl, v_ddl_removals);
        make_create_or_replace(v_ddl, p_obj_type);

        v_len := NVL(DBMS_LOB.GETLENGTH(v_ddl), 0);

        IF v_len = 0 THEN
            IF p_print THEN
                DBMS_OUTPUT.PUT_LINE('-- DDL пуст');
            END IF;
            RETURN;
        END IF;

        IF NOT p_print THEN
            RETURN;
        END IF;

        escape_quotes(v_ddl, v_escaped);

        IF p_obj_type = 'TABLE' THEN
            DBMS_OUTPUT.PUT_LINE('  BEGIN');
            DBMS_OUTPUT.PUT_LINE('    EXECUTE IMMEDIATE ''DROP TABLE ' || v_full_name || ''';');
            DBMS_OUTPUT.PUT_LINE('  EXCEPTION');
            DBMS_OUTPUT.PUT_LINE('    WHEN OTHERS THEN');
            DBMS_OUTPUT.PUT_LINE('      IF SQLCODE = -942 THEN NULL; ELSE RAISE; END IF;');
            DBMS_OUTPUT.PUT_LINE('  END;');
            DBMS_OUTPUT.PUT('  EXECUTE IMMEDIATE ''');
            print_escaped_clob(v_escaped);
            DBMS_OUTPUT.PUT_LINE(''';');
        ELSE
            DBMS_OUTPUT.PUT('  EXECUTE IMMEDIATE ''');
            print_escaped_clob(v_escaped);
            DBMS_OUTPUT.PUT_LINE(''';');
        END IF;

        DBMS_LOB.FREETEMPORARY(v_escaped);
    EXCEPTION
        WHEN OTHERS THEN
            IF p_print THEN
                DBMS_OUTPUT.PUT_LINE('-- Ошибка получения DDL: ' || SQLERRM);
            END IF;
    END output_ddl_for_object;

    PROCEDURE sort_objects(p_list IN OUT t_obj_list) IS
        v_temp t_obj_rec;
    BEGIN
        FOR i IN 1 .. p_list.COUNT - 1 LOOP
            FOR j IN 1 .. p_list.COUNT - i LOOP
                IF p_list(j).owner > p_list(j+1).owner OR
                   (p_list(j).owner = p_list(j+1).owner AND p_list(j).name > p_list(j+1).name) THEN
                    v_temp := p_list(j);
                    p_list(j) := p_list(j+1);
                    p_list(j+1) := v_temp;
                END IF;
            END LOOP;
        END LOOP;
    END sort_objects;

    PROCEDURE check_and_add(p_owner IN VARCHAR2, p_obj_name IN VARCHAR2) IS
        v_key      VARCHAR2(256) := UPPER(p_owner) || '.' || UPPER(p_obj_name);
        v_obj_type VARCHAR2(128);
        v_col_cnt  NUMBER := 0;
    BEGIN
        IF v_checked.EXISTS(v_key) THEN RETURN; END IF;
        v_checked(v_key) := TRUE;

        BEGIN
            SELECT object_type INTO v_obj_type
            FROM all_objects
            WHERE owner = UPPER(p_owner)
              AND object_name = UPPER(p_obj_name)
              AND object_type IN ('TABLE', 'VIEW', 'FUNCTION')
              AND ROWNUM = 1;
        EXCEPTION
            WHEN NO_DATA_FOUND THEN RETURN;
        END;

        IF v_obj_type IN ('TABLE', 'VIEW') THEN
            SELECT COUNT(*) INTO v_col_cnt
            FROM all_tab_columns
            WHERE owner = UPPER(p_owner) AND table_name = UPPER(p_obj_name);
        END IF;

        v_objects.EXTEND;
        v_objects(v_objects.COUNT).owner := UPPER(p_owner);
        v_objects(v_objects.COUNT).name := UPPER(p_obj_name);
        v_objects(v_objects.COUNT).obj_type := v_obj_type;
        v_objects(v_objects.COUNT).col_cnt := v_col_cnt;
    END check_and_add;

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
            check_and_add(v_schema, v_name);
            FOR i IN 1 .. v_schemas.COUNT LOOP
                check_and_add(v_schemas(i), v_name);
            END LOOP;
        ELSE
            add_unqualified(v_name);
            FOR i IN 1 .. v_schemas.COUNT LOOP
                check_and_add(v_schemas(i), v_name);
            END LOOP;
        END IF;
    END process_token;

    FUNCTION build_grant_stmt(p_privilege IN VARCHAR2, p_full_name IN VARCHAR2,
                              p_grantee IN VARCHAR2, p_grantable IN VARCHAR2) RETURN VARCHAR2 IS
    BEGIN
        IF p_grantable = 'YES' THEN
            RETURN 'GRANT ' || p_privilege || ' ON ' || p_full_name || ' TO ' || p_grantee || ' WITH GRANT OPTION';
        ELSE
            RETURN 'GRANT ' || p_privilege || ' ON ' || p_full_name || ' TO ' || p_grantee;
        END IF;
    END build_grant_stmt;

    PROCEDURE output_grants(p_owner IN VARCHAR2, p_name IN VARCHAR2) IS
        v_has_grants BOOLEAN := FALSE;
        v_full_name  VARCHAR2(256) := UPPER(p_owner) || '.' || UPPER(p_name);
    BEGIN
        -- Исключаем объекты из списка v_exclude_from_grants
        IF is_in_list(p_name, v_exclude_from_grants) THEN
            DBMS_OUTPUT.PUT_LINE('  -- (Гранты исключены из вывода для данного объекта)');
            RETURN;
        END IF;

        FOR g IN (
            SELECT DISTINCT privilege, grantee, grantable
            FROM all_tab_privs
            WHERE table_schema = UPPER(p_owner)
              AND table_name = UPPER(p_name)
            ORDER BY grantee, privilege
        ) LOOP
            -- Фильтруем по разрешённым привилегиям в PL/SQL
            IF is_in_list(g.privilege, v_allowed_privs) AND is_in_list(g.grantee, v_grantees) THEN
                DBMS_OUTPUT.PUT_LINE('  EXECUTE IMMEDIATE ''' ||
                    build_grant_stmt(g.privilege, v_full_name, g.grantee, g.grantable) || ''';');
                v_has_grants := TRUE;
            END IF;
        END LOOP;

        IF NOT v_has_grants THEN
            DBMS_OUTPUT.PUT_LINE('  -- (Нет грантов для заданных получателей)');
        END IF;
    END output_grants;

    PROCEDURE check_unqualified_object(
        p_name              IN  VARCHAR2,
        p_missing_by_schema IN OUT t_missing_by_schema
    ) IS
        v_exists_in_all BOOLEAN := TRUE;
        v_obj_types     t_str_list := t_str_list();
        v_normalized_ddls t_clob_list := t_clob_list();
        v_all_same_ddl  BOOLEAN := TRUE;

        TYPE t_grant_info IS RECORD (
            schema_name VARCHAR2(128),
            privilege   VARCHAR2(128),
            grantee     VARCHAR2(128),
            grantable   VARCHAR2(3)
        );
        TYPE t_grant_info_list IS TABLE OF t_grant_info;
        v_all_grants t_grant_info_list := t_grant_info_list();

        TYPE t_unique_grant IS RECORD (
            privilege VARCHAR2(128),
            grantee   VARCHAR2(128),
            grantable VARCHAR2(3)
        );
        TYPE t_unique_grant_list IS TABLE OF t_unique_grant;
        v_unique_grants t_unique_grant_list := t_unique_grant_list();

        v_grants_differ BOOLEAN := FALSE;
        v_raw_ddl CLOB;
        v_should_check_ddl BOOLEAN := FALSE;
        v_skip_grants BOOLEAN := FALSE;
    BEGIN
        FOR i IN 1 .. v_schemas.COUNT LOOP
            DECLARE
                v_obj_type VARCHAR2(128);
            BEGIN
                SELECT object_type INTO v_obj_type
                FROM all_objects
                WHERE owner = UPPER(v_schemas(i))
                  AND object_name = UPPER(p_name)
                  AND object_type IN ('TABLE', 'VIEW', 'FUNCTION')
                  AND ROWNUM = 1;
                v_obj_types.EXTEND;
                v_obj_types(v_obj_types.COUNT) := v_obj_type;
            EXCEPTION
                WHEN NO_DATA_FOUND THEN
                    v_exists_in_all := FALSE;
                    EXIT;
            END;
        END LOOP;

        IF NOT v_exists_in_all THEN
            RETURN;
        END IF;

        DBMS_OUTPUT.PUT_LINE('-- ----------------------------------------');
        DBMS_OUTPUT.PUT_LINE('-- Неквалифицированный объект: ' || UPPER(p_name));
        DBMS_OUTPUT.PUT_LINE('--   Существует во всех схемах: ' || v_schemas.COUNT);

        v_should_check_ddl := matches_ddl_mask(v_schemas(1), p_name, v_ddl_objects);

        IF v_should_check_ddl THEN
            FOR i IN 1 .. v_schemas.COUNT LOOP
                v_raw_ddl := DBMS_METADATA.GET_DDL(
                    object_type => v_obj_types(i),
                    name        => UPPER(p_name),
                    schema      => UPPER(v_schemas(i))
                );

                v_normalized_ddls.EXTEND;
                v_normalized_ddls(v_normalized_ddls.COUNT) := normalize_ddl_for_compare(v_raw_ddl, v_schemas(i));
            END LOOP;

            FOR i IN 2 .. v_normalized_ddls.COUNT LOOP
                IF v_normalized_ddls(1) IS NULL OR v_normalized_ddls(i) IS NULL THEN
                    v_all_same_ddl := FALSE;
                ELSIF DBMS_LOB.COMPARE(v_normalized_ddls(1), v_normalized_ddls(i)) != 0 THEN
                    v_all_same_ddl := FALSE;
                END IF;
            END LOOP;

            IF NOT v_all_same_ddl THEN
                DBMS_OUTPUT.PUT_LINE('--   ВНИМАНИЕ: DDL РАЗЛИЧАЕТСЯ между схемами!');
                FOR i IN 1 .. v_schemas.COUNT LOOP
                    DBMS_OUTPUT.PUT_LINE('--     - ' || v_schemas(i) || ' (' || v_obj_types(i) || ')');
                END LOOP;
            ELSE
                DBMS_OUTPUT.PUT_LINE('--   DDL одинаков во всех схемах');
            END IF;

            FOR i IN 1 .. v_normalized_ddls.COUNT LOOP
                IF v_normalized_ddls(i) IS NOT NULL THEN
                    BEGIN DBMS_LOB.FREETEMPORARY(v_normalized_ddls(i)); EXCEPTION WHEN OTHERS THEN NULL; END;
                END IF;
            END LOOP;
        ELSE
            DBMS_OUTPUT.PUT_LINE('--   DDL не проверяется (объект не удовлетворяет маске)');
        END IF;

        -- Проверяем, исключён ли объект из проверки грантов
        v_skip_grants := is_in_list(p_name, v_exclude_from_grants);

        IF v_skip_grants THEN
            DBMS_OUTPUT.PUT_LINE('--   Гранты исключены из проверки для данного объекта');
            RETURN;
        END IF;

        -- Собираем все гранты из всех схем
        FOR i IN 1 .. v_schemas.COUNT LOOP
            FOR g IN (
                SELECT DISTINCT privilege, grantee, grantable
                FROM all_tab_privs
                WHERE table_schema = UPPER(v_schemas(i))
                  AND table_name = UPPER(p_name)
            ) LOOP
                -- Фильтруем по разрешённым привилегиям и получателям в PL/SQL
                IF is_in_list(g.privilege, v_allowed_privs) AND is_in_list(g.grantee, v_grantees) THEN
                    v_all_grants.EXTEND;
                    v_all_grants(v_all_grants.COUNT).schema_name := v_schemas(i);
                    v_all_grants(v_all_grants.COUNT).privilege := g.privilege;
                    v_all_grants(v_all_grants.COUNT).grantee := g.grantee;
                    v_all_grants(v_all_grants.COUNT).grantable := g.grantable;

                    DECLARE
                        v_found BOOLEAN := FALSE;
                    BEGIN
                        FOR j IN 1 .. v_unique_grants.COUNT LOOP
                            IF v_unique_grants(j).privilege = g.privilege
                               AND v_unique_grants(j).grantee = g.grantee
                               AND v_unique_grants(j).grantable = g.grantable THEN
                                v_found := TRUE;
                                EXIT;
                            END IF;
                        END LOOP;
                        IF NOT v_found THEN
                            v_unique_grants.EXTEND;
                            v_unique_grants(v_unique_grants.COUNT).privilege := g.privilege;
                            v_unique_grants(v_unique_grants.COUNT).grantee := g.grantee;
                            v_unique_grants(v_unique_grants.COUNT).grantable := g.grantable;
                        END IF;
                    END;
                END IF;
            END LOOP;
        END LOOP;

        FOR u IN 1 .. v_unique_grants.COUNT LOOP
            FOR i IN 1 .. v_schemas.COUNT LOOP
                DECLARE
                    v_exists BOOLEAN := FALSE;
                BEGIN
                    FOR g IN 1 .. v_all_grants.COUNT LOOP
                        IF v_all_grants(g).schema_name = v_schemas(i)
                           AND v_all_grants(g).privilege = v_unique_grants(u).privilege
                           AND v_all_grants(g).grantee = v_unique_grants(u).grantee
                           AND v_all_grants(g).grantable = v_unique_grants(u).grantable THEN
                            v_exists := TRUE;
                            EXIT;
                        END IF;
                    END LOOP;

                    IF NOT v_exists THEN
                        v_grants_differ := TRUE;

                        DECLARE
                            v_schema_key VARCHAR2(128) := v_schemas(i);
                            v_new_grant  t_missing_grant;
                        BEGIN
                            v_new_grant.privilege := v_unique_grants(u).privilege;
                            v_new_grant.obj_name  := UPPER(p_name);
                            v_new_grant.grantee   := v_unique_grants(u).grantee;
                            v_new_grant.grantable := v_unique_grants(u).grantable;

                            IF NOT p_missing_by_schema.EXISTS(v_schema_key) THEN
                                p_missing_by_schema(v_schema_key) := t_missing_grant_list();
                            END IF;

                            p_missing_by_schema(v_schema_key).EXTEND;
                            p_missing_by_schema(v_schema_key)(p_missing_by_schema(v_schema_key).COUNT) := v_new_grant;
                        END;
                    END IF;
                END;
            END LOOP;
        END LOOP;

        IF NOT v_grants_differ THEN
            DBMS_OUTPUT.PUT_LINE('--   Гранты одинаковы во всех схемах');
        ELSE
            DBMS_OUTPUT.PUT_LINE('--   ВНИМАНИЕ: ГРАНТЫ РАЗЛИЧАЮТСЯ (см. блок недостающих грантов ниже)');
        END IF;
    END check_unqualified_object;

BEGIN
    DBMS_OUTPUT.PUT_LINE('BEGIN');
    DBMS_OUTPUT.PUT_LINE('-- Начало анализа пакета ' || c_pkg_owner || '.' || c_pkg_name);
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

    IF v_objects.COUNT > 0 THEN
        sort_objects(v_objects);

        DECLARE
            v_current_owner VARCHAR2(128) := NULL;
            v_block_opened  BOOLEAN := FALSE;
        BEGIN
            FOR i IN 1 .. v_objects.COUNT LOOP
                IF v_objects(i).owner != v_current_owner THEN
                    IF v_block_opened THEN
                        DBMS_OUTPUT.PUT_LINE('END;');
                        DBMS_OUTPUT.PUT_LINE('-- >>> КОНЕЦ БЛОКА ДЛЯ СХЕМЫ: ' || v_current_owner || ' <<<');
                        DBMS_OUTPUT.PUT_LINE('');
                    END IF;

                    v_current_owner := v_objects(i).owner;
                    DBMS_OUTPUT.PUT_LINE('-- >>> НАЧАЛО БЛОКА ДЛЯ СХЕМЫ: ' || v_current_owner || ' <<<');
                    DBMS_OUTPUT.PUT_LINE('-- ==========================================================');
                    DBMS_OUTPUT.PUT_LINE('-- СХЕМА: ' || v_current_owner);
                    DBMS_OUTPUT.PUT_LINE('-- Выполнять в схеме ' || v_current_owner);
                    DBMS_OUTPUT.PUT_LINE('BEGIN');
                    v_block_opened := TRUE;
                END IF;

                DBMS_OUTPUT.PUT_LINE('  -- ----------------------------------------------------------');
                DBMS_OUTPUT.PUT_LINE('  -- Объект: ' || v_objects(i).owner || '.' || v_objects(i).name);
                DBMS_OUTPUT.PUT_LINE('  -- Тип:    ' || v_objects(i).obj_type);
                DBMS_OUTPUT.PUT_LINE('  -- Колонок: ' || CASE WHEN v_objects(i).obj_type = 'FUNCTION' THEN 'N/A (Функция)' ELSE TO_CHAR(v_objects(i).col_cnt) END);

                IF matches_ddl_mask(v_objects(i).owner, v_objects(i).name, v_ddl_objects) THEN
                    output_ddl_for_object(v_objects(i).owner, v_objects(i).name, v_objects(i).obj_type, TRUE);
                END IF;

                DBMS_OUTPUT.PUT_LINE('  -- Гранты для заданных получателей:');
                output_grants(v_objects(i).owner, v_objects(i).name);
            END LOOP;

            IF v_block_opened THEN
                DBMS_OUTPUT.PUT_LINE('END;');
                DBMS_OUTPUT.PUT_LINE('-- >>> КОНЕЦ БЛОКА ДЛЯ СХЕМЫ: ' || v_current_owner || ' <<<');
                DBMS_OUTPUT.PUT_LINE('');
            END IF;
        END;
    END IF;

    IF v_unqualified.COUNT > 0 THEN
        DECLARE
            v_missing_by_schema t_missing_by_schema;
            v_schema_list       t_str_list := t_str_list();
        BEGIN
            FOR i IN 1 .. v_unqualified.COUNT LOOP
                check_unqualified_object(v_unqualified(i), v_missing_by_schema);
            END LOOP;

            IF v_missing_by_schema.COUNT > 0 THEN
                DECLARE
                    v_key VARCHAR2(128);
                BEGIN
                    v_key := v_missing_by_schema.FIRST;
                    WHILE v_key IS NOT NULL LOOP
                        v_schema_list.EXTEND;
                        v_schema_list(v_schema_list.COUNT) := v_key;
                        v_key := v_missing_by_schema.NEXT(v_key);
                    END LOOP;
                END;

                FOR i IN 1 .. v_schema_list.COUNT - 1 LOOP
                    FOR j IN 1 .. v_schema_list.COUNT - i LOOP
                        IF v_schema_list(j) > v_schema_list(j+1) THEN
                            DECLARE
                                v_tmp VARCHAR2(128);
                            BEGIN
                                v_tmp := v_schema_list(j);
                                v_schema_list(j) := v_schema_list(j+1);
                                v_schema_list(j+1) := v_tmp;
                            END;
                        END IF;
                    END LOOP;
                END LOOP;

                DBMS_OUTPUT.PUT_LINE('');
                DBMS_OUTPUT.PUT_LINE('-- >>> НАЧАЛО БЛОКА ПРОВЕРКИ НЕКВАЛИФИЦИРОВАННЫХ ОБЪЕКТОВ <<<');
                DBMS_OUTPUT.PUT_LINE('-- ==========================================================');
                DBMS_OUTPUT.PUT_LINE('-- Недостающие гранты, сгруппированные по схеме');
                DBMS_OUTPUT.PUT_LINE('-- ==========================================================');

                FOR s IN 1 .. v_schema_list.COUNT LOOP
                    DECLARE
                        v_schema_name VARCHAR2(128) := v_schema_list(s);
                        v_grants_list t_missing_grant_list := v_missing_by_schema(v_schema_name);
                    BEGIN
                        DBMS_OUTPUT.PUT_LINE('');
                        DBMS_OUTPUT.PUT_LINE('-- >>> НАЧАЛО БЛОКА ДОПОЛНЕНИЯ ГРАНТОВ ДЛЯ СХЕМЫ: ' || v_schema_name || ' <<<');
                        DBMS_OUTPUT.PUT_LINE('-- СХЕМА: ' || v_schema_name);
                        DBMS_OUTPUT.PUT_LINE('-- Выполнять в схеме ' || v_schema_name);
                        DBMS_OUTPUT.PUT_LINE('BEGIN');

                        FOR g IN 1 .. v_grants_list.COUNT LOOP
                            DBMS_OUTPUT.PUT_LINE('  EXECUTE IMMEDIATE ''' ||
                                build_grant_stmt(
                                    v_grants_list(g).privilege,
                                    v_schema_name || '.' || v_grants_list(g).obj_name,
                                    v_grants_list(g).grantee,
                                    v_grants_list(g).grantable
                                ) || ''';');
                        END LOOP;

                        DBMS_OUTPUT.PUT_LINE('END;');
                        DBMS_OUTPUT.PUT_LINE('-- >>> КОНЕЦ БЛОКА ДОПОЛНЕНИЯ ГРАНТОВ ДЛЯ СХЕМЫ: ' || v_schema_name || ' <<<');
                    END;
                END LOOP;

                DBMS_OUTPUT.PUT_LINE('');
                DBMS_OUTPUT.PUT_LINE('-- >>> КОНЕЦ БЛОКА ПРОВЕРКИ НЕКВАЛИФИЦИРОВАННЫХ ОБЪЕКТОВ <<<');
            ELSE
                DBMS_OUTPUT.PUT_LINE('');
                DBMS_OUTPUT.PUT_LINE('-- >>> НАЧАЛО БЛОКА ПРОВЕРКИ НЕКВАЛИФИЦИРОВАННЫХ ОБЪЕКТОВ <<<');
                DBMS_OUTPUT.PUT_LINE('-- Все гранты одинаковы во всех схемах. Недостающих грантов нет.');
                DBMS_OUTPUT.PUT_LINE('-- >>> КОНЕЦ БЛОКА ПРОВЕРКИ НЕКВАЛИФИЦИРОВАННЫХ ОБЪЕКТОВ <<<');
            END IF;
        END;
    END IF;

    DBMS_OUTPUT.PUT_LINE('');
    DBMS_OUTPUT.PUT_LINE('-- Анализ завершен.');
    DBMS_OUTPUT.PUT_LINE('END;');

END;
