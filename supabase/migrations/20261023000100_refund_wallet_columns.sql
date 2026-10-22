SET lock_timeout = '10s';

-- Refunds of bills paid partly from the cashback wallet, and clawing back a
-- reward the refunded bill earned. amount stays "money handed back".
ALTER TABLE public.order_refunds
  ADD COLUMN IF NOT EXISTS wallet_amount numeric NOT NULL DEFAULT 0 CHECK (wallet_amount >= 0),
  ADD COLUMN IF NOT EXISTS reward_clawback numeric NOT NULL DEFAULT 0 CHECK (reward_clawback >= 0),
  ADD COLUMN IF NOT EXISTS cash_withheld numeric NOT NULL DEFAULT 0 CHECK (cash_withheld >= 0),
  ADD COLUMN IF NOT EXISTS cashback_done boolean NOT NULL DEFAULT false;
COMMENT ON COLUMN public.order_refunds.amount IS 'Money handed back through method_key (drawer / card / tab).';
COMMENT ON COLUMN public.order_refunds.wallet_amount IS 'Part of the refund credited back to the customer cashback wallet (the bill was partly paid from it).';
COMMENT ON COLUMN public.order_refunds.reward_clawback IS 'Cashback reward earned on this bill that the refund took back.';
COMMENT ON COLUMN public.order_refunds.cash_withheld IS 'Part of reward_clawback the customer had already spent, kept out of the cash refund.';
COMMENT ON COLUMN public.order_refunds.cashback_done IS 'Wallet/progress already handled by refund_order_items; trg_refund_cashback skips it.';
-- A bill paid fully from the wallet refunds 0 cash.
ALTER TABLE public.order_refunds DROP CONSTRAINT order_refunds_amount_check;
ALTER TABLE public.order_refunds ADD CONSTRAINT order_refunds_amount_check
  CHECK (amount >= 0 AND (amount > 0 OR wallet_amount > 0 OR cash_withheld > 0));
