CREATE TABLE IF NOT EXISTS api_keys (
    id SERIAL PRIMARY KEY,
    name VARCHAR(100) NOT NULL,
    
    -- key_hash armazena o hash SHA-256 da chave, que tem 64 caracteres hexadecimais
    key_hash VARCHAR(64) NOT NULL UNIQUE, 
    
    is_active BOOLEAN DEFAULT true,
    created_at TIMESTAMP WITH TIME ZONE DEFAULT CURRENT_TIMESTAMP
);

-- Insere a chave pré-definida para o evaluation-service
INSERT INTO api_keys (name, key_hash) 
VALUES ('evaluation-service', 'd07d40e087c9285948931e377cef1bc2536963aec413037f8921946e6d476c4e')
ON CONFLICT (key_hash) DO NOTHING;