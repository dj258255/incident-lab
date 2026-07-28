INSERT INTO quote (symbol, price) VALUES ('005930', 70000)
ON CONFLICT (symbol) DO NOTHING;
