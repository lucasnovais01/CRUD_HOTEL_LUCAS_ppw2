-- ######################################################################
-- #            TRIGGERS ESSENCIAIS CRÍTICOS (TIPO NUMÉRICO)            #
-- ######################################################################

-- =========================================================================================
-- T00: AUDITORIA GLOBAL E VALIDAÇÃO DE DATA_NASCIMENTO (COCAO_USUARIO)
-- FINALIDADE: Garante updated_at/created_at e validações de data na tabela pai.
-- =========================================================================================
CREATE OR REPLACE TRIGGER TRG_COCAO_USUARIO_AUDITORIA
BEFORE INSERT OR UPDATE ON COCAO_USUARIO
FOR EACH ROW
BEGIN
    -- [1] Auditoria: Atualiza UPDATED_AT e garante CREATED_AT.
    IF INSERTING THEN
        :NEW.CREATED_AT := CURRENT_TIMESTAMP;
    END IF;
    :NEW.UPDATED_AT := CURRENT_TIMESTAMP;
    
    -- [2] Validação DATA_NASCIMENTO: Não pode ser no futuro.
    IF :NEW.DATA_NASCIMENTO > SYSDATE THEN
        RAISE_APPLICATION_ERROR(-20001, 'Data de nascimento não pode ser futura.');
    END IF;
END;

COMMENT ON TRIGGER TRG_COCAO_USUARIO_AUDITORIA IS 'Garante Updated_At, Created_At e valida DATA_NASCIMENTO.';

-- =========================================================================================
-- T01: HÓSPEDE - EXCLUSIVIDADE E TIPO=0 (ANTES DA INSERÇÃO)
-- FINALIDADE: Impede ID duplicado em FUNCIONARIO e exige TIPO=0 (Hóspede).
-- =========================================================================================
CREATE OR REPLACE TRIGGER TRG_COCAO_USUARIO_HOSPEDE
BEFORE INSERT ON COCAO_HOSPEDE
FOR EACH ROW
DECLARE
    v_tipo_usuario NUMBER(1);
    v_funcionario_count NUMBER;
BEGIN
    -- [1] Verifica se já existe como FUNCIONÁRIO (Exclusividade Mútua)
    SELECT COUNT(*) INTO v_funcionario_count     
    FROM COCAO_FUNCIONARIO WHERE ID_USUARIO = :NEW.ID_USUARIO;
        
    IF v_funcionario_count > 0 THEN
        RAISE_APPLICATION_ERROR(-20005, 'Usuário já é FUNCIONÁRIO. Não pode ser HÓSPEDE.');
    END IF;
        
    -- [2] Verifica TIPO na tabela pai (Consistência de TIPO=0)
    -- TIPO 1 (Funcionário) deve ser verificado. O DEFAULT 0 ajuda a manter a consistência.
    SELECT TIPO INTO v_tipo_usuario FROM COCAO_USUARIO WHERE ID_USUARIO = :NEW.ID_USUARIO;
        
    IF v_tipo_usuario = 1 THEN -- Se for 1 (Funcionário)
        RAISE_APPLICATION_ERROR(-20006, 'TIPO do usuário na COCAO_USUARIO é 1 (Funcionário). Deve ser 0 para HÓSPEDE.');
    END IF;
        
    -- [3] Atualiza UPDATED_AT na subclasse
    :NEW.UPDATED_AT := CURRENT_TIMESTAMP;
END;

COMMENT ON TRIGGER TRG_COCAO_USUARIO_HOSPEDE IS 'Garante exclusividade mútua (contra FUNCIONARIO) e consistência de TIPO=0 (Hóspede).';

-- =========================================================================================
-- T02: FUNCIONÁRIO - EXCLUSIVIDADE E TIPO=1 (ANTES DA INSERÇÃO)
-- FINALIDADE: Impede ID duplicado em HOSPEDE, valida Data de Contratação e TIPO=1.
-- =========================================================================================
CREATE OR REPLACE TRIGGER TRG_COCAO_USUARIO_FUNCIONARIO
BEFORE INSERT ON COCAO_FUNCIONARIO
FOR EACH ROW
DECLARE
    v_tipo_usuario NUMBER(1);
    v_hospede_count NUMBER;
BEGIN
    -- [1] Verifica se já existe como HÓSPEDE (Exclusividade Mútua)
    SELECT COUNT(*) INTO v_hospede_count     
    FROM COCAO_HOSPEDE WHERE ID_USUARIO = :NEW.ID_USUARIO;
        
    IF v_hospede_count > 0 THEN
        RAISE_APPLICATION_ERROR(-20003, 'Usuário já é HÓSPEDE. Não pode ser FUNCIONÁRIO.');
    END IF;
        
    -- [2] Valida DATA_CONTRATACAO: Não pode ser no futuro.
    IF :NEW.DATA_CONTRATACAO > SYSDATE THEN
        RAISE_APPLICATION_ERROR(-20002, 'Data de contratação não pode ser futura.');
    END IF;
        
    -- [3] Verifica TIPO na tabela pai (Consistência de TIPO=1)
    SELECT TIPO INTO v_tipo_usuario FROM COCAO_USUARIO WHERE ID_USUARIO = :NEW.ID_USUARIO;
        
    IF v_tipo_usuario = 0 THEN -- Se for 0 (Hóspede)
        RAISE_APPLICATION_ERROR(-20004, 'TIPO do usuário na COCAO_USUARIO é 0 (Hóspede). Deve ser 1 para FUNCIONÁRIO.');
    END IF;
    
    -- [4] Atualiza UPDATED_AT na subclasse
    :NEW.UPDATED_AT := CURRENT_TIMESTAMP;
END;

COMMENT ON TRIGGER TRG_COCAO_USUARIO_FUNCIONARIO IS 'Garante exclusividade mútua (contra HOSPEDE), consistência de TIPO=1 (Funcionário) e valida DATA_CONTRATACAO.';

-- =========================================================================================
-- T03 a T05 (RESERVA, QUARTO, SERVIÇO, etc.) PERMANECEM INALTERADOS
-- =========================================================================================

-- T03: RESERVA - CONFLITO DE DATAS (SOBREPOSIÇÃO)
CREATE OR REPLACE TRIGGER TRG_COCAO_RESERVA_CONFLITO
BEFORE INSERT OR UPDATE ON COCAO_RESERVA
FOR EACH ROW
DECLARE
    v_conflito_count NUMBER;
BEGIN
    :NEW.UPDATED_AT := CURRENT_TIMESTAMP;
    SELECT COUNT(*) INTO v_conflito_count
    FROM COCAO_RESERVA r
    WHERE r.ID_QUARTO = :NEW.ID_QUARTO
      AND r.ID_RESERVA != NVL(:NEW.ID_RESERVA, -1)
      AND r.STATUS_RESERVA IN ('ATIVA', 'ABERTA')
      AND r.DATA_CHECK_OUT > :NEW.DATA_CHECK_IN     
      AND r.DATA_CHECK_IN < :NEW.DATA_CHECK_OUT;
    
    IF v_conflito_count > 0 THEN
        RAISE_APPLICATION_ERROR(-20008, 'Conflito: Quarto já reservado no período solicitado.');
    END IF;
END;

COMMENT ON TRIGGER TRG_COCAO_RESERVA_CONFLITO IS 'Garante que não haja sobreposição de datas com outras reservas ativas/abertas no mesmo quarto.';

-- T04: RESERVA AFTER (SINCRONIZA STATUS QUARTO)
CREATE OR REPLACE TRIGGER TRG_COCAO_RESERVA_STATUS_QUARTO
AFTER INSERT OR UPDATE OF STATUS_RESERVA, DATA_CHECK_IN, DATA_CHECK_OUT ON COCAO_RESERVA
FOR EACH ROW
DECLARE
    v_reservas_futuras NUMBER;
BEGIN
    IF :NEW.STATUS_RESERVA IN ('ATIVA', 'ABERTA') AND :NEW.DATA_CHECK_OUT > TRUNC(SYSDATE) THEN
        UPDATE COCAO_QUARTO 
        SET STATUS_QUARTO = 'OCUPADO', UPDATED_AT = CURRENT_TIMESTAMP
        WHERE ID_QUARTO = :NEW.ID_QUARTO
          AND STATUS_QUARTO != 'MANUTENCAO';

    ELSIF :NEW.STATUS_RESERVA IN ('FINALIZADA', 'CANCELADA') THEN
        SELECT COUNT(*) INTO v_reservas_futuras
        FROM COCAO_RESERVA r
        WHERE r.ID_QUARTO = :NEW.ID_QUARTO
          AND r.STATUS_RESERVA IN ('ATIVA', 'ABERTA')
          AND r.DATA_CHECK_OUT > TRUNC(SYSDATE)
          AND r.ID_RESERVA != :NEW.ID_RESERVA;
                
        IF v_reservas_futuras = 0 THEN
            UPDATE COCAO_QUARTO 
            SET STATUS_QUARTO = 'LIVRE', UPDATED_AT = CURRENT_TIMESTAMP
            WHERE ID_QUARTO = :NEW.ID_QUARTO
              AND STATUS_QUARTO != 'MANUTENCAO';
        END IF;
    END IF;
END;

COMMENT ON TRIGGER TRG_COCAO_RESERVA_STATUS_QUARTO IS 'Sincroniza o STATUS_QUARTO na COCAO_QUARTO baseado no status e datas da COCAO_RESERVA (pós-operação).';

-- T05: RESERVA AFTER DELETE (LIBERA O QUARTO)
CREATE OR REPLACE TRIGGER TRG_COCAO_RESERVA_DEPOIS_DELETE
AFTER DELETE ON COCAO_RESERVA
FOR EACH ROW
DECLARE
    v_reservas_ativas_count NUMBER;
BEGIN
    SELECT COUNT(*)
    INTO v_reservas_ativas_count
    FROM COCAO_RESERVA
    WHERE ID_QUARTO = :OLD.ID_QUARTO
      AND STATUS_RESERVA IN ('ATIVA', 'ABERTA')
      AND DATA_CHECK_OUT > TRUNC(SYSDATE);

    IF v_reservas_ativas_count = 0 THEN
        UPDATE COCAO_QUARTO
        SET STATUS_QUARTO = 'LIVRE', UPDATED_AT = CURRENT_TIMESTAMP
        WHERE ID_QUARTO = :OLD.ID_QUARTO
          AND STATUS_QUARTO != 'MANUTENCAO';
    END IF;
END;

COMMENT ON TRIGGER TRG_COCAO_RESERVA_DEPOIS_DELETE IS 'Libera o quarto após a exclusão de uma reserva, se não houver mais reservas ativas/abertas para o quarto.';
