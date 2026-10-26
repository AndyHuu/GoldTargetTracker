"""Focused income attribution checks, using the same Lua 5.1 harness."""
import test_addon
import unittest


class IncomeTests(unittest.TestCase):
    setUp = test_addon.AddonTests.setUp
    run_lua = test_addon.AddonTests.run_lua
    boot = test_addon.AddonTests.boot

    def totals(self, body):
        self.run_lua("local totals=db.incomeSources.totals; " + body)

    def test_income_starts_empty_without_recounting_wallet(self):
        self.boot()
        self.totals("assert(next(totals)==nil); assert(db.incomeSources.startedAt==time())")
        self.run_lua("api.OnEvent(frames[1],'PLAYER_MONEY'); advance(2)")
        self.totals("assert(next(totals)==nil)")

    def test_world_quest_evidence_before_and_after_money(self):
        self.boot()
        self.run_lua("worldQuests[101]=true; api.OnEvent(frames[1],'QUEST_TURNED_IN',101,0,12345); money=money+12345; api.OnEvent(frames[1],'PLAYER_MONEY'); api.OnEvent(frames[1],'PLAYER_MONEY'); api.OnEvent(frames[1],'QUEST_TURNED_IN',101,0,12345); advance(2)")
        self.totals("assert(totals.worldQuest==12345 and not totals.other)")
        self.run_lua("money=money+23456; api.OnEvent(frames[1],'PLAYER_MONEY'); api.OnEvent(frames[1],'QUEST_TURNED_IN',102,0,23456); advance(2)")
        self.totals("assert(totals.quest==23456)")

    def test_unknown_income_expense_and_repeated_amount(self):
        self.boot()
        self.run_lua("money=money+101; api.OnEvent(frames[1],'PLAYER_MONEY'); advance(2); money=money-200; api.OnEvent(frames[1],'PLAYER_MONEY'); money=money+101; api.OnEvent(frames[1],'PLAYER_MONEY'); advance(2)")
        self.totals("assert(totals.other==202)")

    def test_no_quest_income_without_wallet_confirmation(self):
        self.boot()
        self.run_lua("api.OnEvent(frames[1],'QUEST_TURNED_IN',101,0,12345); advance(3); money=money+12345; api.OnEvent(frames[1],'PLAYER_MONEY'); advance(2)")
        self.totals("assert(totals.other==12345 and not totals.quest)")

    def test_vendor_sales_need_bag_evidence_not_only_open_window(self):
        self.boot()
        self.run_lua("setItem(0,1,3); api.OnEvent(frames[1],'MERCHANT_SHOW'); setItem(0,1,1); buybacks={{id=1,price=246,count=2}}; money=money+246; api.OnEvent(frames[1],'PLAYER_MONEY'); api.OnEvent(frames[1],'BAG_UPDATE_DELAYED'); api.OnEvent(frames[1],'MERCHANT_UPDATE'); advance(2)")
        self.totals("assert(totals.vendor==246)")
        self.run_lua("money=money+123; api.OnEvent(frames[1],'PLAYER_MONEY'); advance(2)")
        self.totals("assert(totals.vendor==246 and totals.other==123)")

    def test_destroying_item_at_merchant_does_not_claim_unknown_income(self):
        self.boot()
        self.run_lua("setItem(0,1,3); api.OnEvent(frames[1],'MERCHANT_SHOW'); setItem(0,1,2); api.OnEvent(frames[1],'BAG_UPDATE_DELAYED'); money=money+123; api.OnEvent(frames[1],'PLAYER_MONEY'); advance(2)")
        self.totals("assert(totals.other==123 and not totals.vendor)")

    def test_bank_withdrawal_wallet_first_and_bank_first(self):
        self.run_lua("bankReady=true; bankMoney=90000")
        self.boot()
        self.run_lua("C_Bank.WithdrawMoney(2,10000); money=money+10000; api.OnEvent(frames[1],'PLAYER_MONEY'); bankMoney=80000; api.OnEvent(frames[1],'ACCOUNT_MONEY'); advance(2)")
        self.totals("assert(next(totals)==nil)")
        self.run_lua("C_Bank.WithdrawMoney(2,20000); bankMoney=60000; api.OnEvent(frames[1],'ACCOUNT_MONEY'); money=money+20000; api.OnEvent(frames[1],'PLAYER_MONEY'); advance(2)")
        self.totals("assert(next(totals)==nil)")

    def test_bank_deposit_does_not_reduce_income_or_suppress_other_income(self):
        self.run_lua("bankReady=true; bankMoney=90000")
        self.boot()
        self.run_lua("api.OnEvent(frames[1],'BANKFRAME_OPENED'); money=money+500; api.OnEvent(frames[1],'PLAYER_MONEY'); advance(2); money=money-10000; bankMoney=100000; api.OnEvent(frames[1],'PLAYER_MONEY'); api.OnEvent(frames[1],'ACCOUNT_MONEY'); advance(2)")
        self.totals("assert(totals.other==500)")

    def test_failed_withdrawal_does_not_suppress_unrelated_income(self):
        self.run_lua("bankReady=true; bankMoney=90000")
        self.boot()
        self.run_lua("C_Bank.WithdrawMoney(2,500); money=money+500; api.OnEvent(frames[1],'PLAYER_MONEY'); advance(2)")
        self.totals("assert(totals.other==500)")

    def test_bank_events_inside_api_call_before_secure_post_hook(self):
        self.run_lua("bankReady=true; bankMoney=90000; C_Bank.WithdrawMoney=function(kind,amount) bankMoney=bankMoney-amount; money=money+amount; api.OnEvent(frames[1],'PLAYER_MONEY'); api.OnEvent(frames[1],'ACCOUNT_MONEY') end")
        self.boot()
        self.run_lua("C_Bank.WithdrawMoney(2,500); advance(2)")
        self.totals("assert(next(totals)==nil)")

    def test_guild_bank_withdrawal_and_unrelated_receipt(self):
        self.boot()
        self.run_lua("guildMoney=50000; api.OnEvent(frames[1],'GUILDBANKFRAME_OPENED'); WithdrawGuildBankMoney(5000); guildMoney=45000; api.OnEvent(frames[1],'GUILDBANK_UPDATE_MONEY'); money=money+5000; api.OnEvent(frames[1],'PLAYER_MONEY'); advance(2); money=money+555; api.OnEvent(frames[1],'PLAYER_MONEY'); advance(2)")
        self.totals("assert(totals.other==555)")

    def test_mixed_bank_and_quest_in_one_wallet_update(self):
        self.run_lua("bankReady=true; bankMoney=90000")
        self.boot()
        self.run_lua("C_Bank.WithdrawMoney(2,10000); bankMoney=80000; api.OnEvent(frames[1],'ACCOUNT_MONEY'); api.OnEvent(frames[1],'QUEST_TURNED_IN',103,0,321); money=money+10321; api.OnEvent(frames[1],'PLAYER_MONEY'); advance(2)")
        self.totals("assert(totals.quest==321 and not totals.other)")

    def test_mixed_auction_and_plain_mail_batch_and_repeated_request(self):
        self.boot()
        self.run_lua("inbox={{amount=12345,invoice='seller'},{amount=6789},{amount=300,invoice='seller_temp_invoice'}}; api.OnEvent(frames[1],'MAIL_SHOW'); TakeInboxMoney(1); TakeInboxMoney(1); TakeInboxMoney(2); money=money+19134; api.OnEvent(frames[1],'PLAYER_MONEY'); api.OnEvent(frames[1],'MAIL_CLOSED'); advance(2)")
        self.totals("assert(totals.auction==12345 and totals.mail==6789 and not totals.other)")

    def test_identical_auction_mails_can_shift_to_same_index(self):
        self.boot()
        self.run_lua("inbox={{amount=500,invoice='seller',subject='Same'},{amount=500,invoice='seller',subject='Same'}}; api.OnEvent(frames[1],'MAIL_SHOW'); TakeInboxMoney(1); money=money+500; api.OnEvent(frames[1],'PLAYER_MONEY'); table.remove(inbox,1); api.OnEvent(frames[1],'MAIL_INBOX_UPDATE'); TakeInboxMoney(1); money=money+500; api.OnEvent(frames[1],'PLAYER_MONEY'); advance(2)")
        self.totals("assert(totals.auction==1000 and not totals.other)")

    def test_closed_guild_bank_zero_is_not_a_withdrawal(self):
        self.boot()
        self.run_lua("guildMoney=50000; api.OnEvent(frames[1],'GUILDBANKFRAME_OPENED'); guildMoney=0; api.OnEvent(frames[1],'GUILDBANKFRAME_CLOSED'); money=money+500; api.OnEvent(frames[1],'PLAYER_MONEY'); advance(2)")
        self.totals("assert(totals.other==500)")

    def test_other_members_guild_withdrawal_does_not_suppress_quest(self):
        self.boot()
        self.run_lua("guildMoney=50000; api.OnEvent(frames[1],'GUILDBANKFRAME_OPENED'); guildMoney=45000; api.OnEvent(frames[1],'GUILDBANK_UPDATE_MONEY'); api.OnEvent(frames[1],'QUEST_TURNED_IN',103,0,5000); money=money+5000; api.OnEvent(frames[1],'PLAYER_MONEY'); advance(2)")
        self.totals("assert(totals.quest==5000)")

    def test_trade_cancel_after_close_cannot_claim_other_receipt(self):
        self.boot()
        self.run_lua("api.OnEvent(frames[1],'TRADE_SHOW'); tradeMoney=500; api.OnEvent(frames[1],'TRADE_ACCEPT_UPDATE',1,1); api.OnEvent(frames[1],'TRADE_CLOSED'); api.OnEvent(frames[1],'TRADE_REQUEST_CANCEL'); money=money+500; api.OnEvent(frames[1],'PLAYER_MONEY'); advance(2)")
        self.totals("assert(totals.other==500 and not totals.trade)")

    def test_pending_auction_and_failed_mail_do_not_create_income(self):
        self.boot()
        self.run_lua("inbox={{amount=0,invoice='seller_temp_invoice'},{amount=500}}; api.OnEvent(frames[1],'MAIL_SHOW'); TakeInboxMoney(1); TakeInboxMoney(2); api.OnEvent(frames[1],'MAIL_FAILED'); money=money+500; api.OnEvent(frames[1],'PLAYER_MONEY'); advance(2)")
        self.totals("assert(totals.other==500 and not totals.auction and not totals.mail)")

    def test_trade_success_and_cancel(self):
        self.boot()
        self.run_lua("api.OnEvent(frames[1],'TRADE_SHOW'); tradeMoney=234; api.OnEvent(frames[1],'TRADE_MONEY_CHANGED'); api.OnEvent(frames[1],'TRADE_ACCEPT_UPDATE',1,1); money=money+234; api.OnEvent(frames[1],'PLAYER_MONEY'); api.OnEvent(frames[1],'TRADE_CLOSED'); advance(2)")
        self.totals("assert(totals.trade==234)")
        self.run_lua("api.OnEvent(frames[1],'TRADE_SHOW'); tradeMoney=234; api.OnEvent(frames[1],'TRADE_ACCEPT_UPDATE',1,0); api.OnEvent(frames[1],'TRADE_REQUEST_CANCEL'); api.OnEvent(frames[1],'TRADE_CLOSED'); money=money+234; api.OnEvent(frames[1],'PLAYER_MONEY'); advance(2)")
        self.totals("assert(totals.trade==234 and totals.other==234)")

    def test_loot_coin_units_and_quest_priority(self):
        self.boot()
        self.run_lua("api.OnEvent(frames[1],'CHAT_MSG_MONEY','你获得了1金币2银币3铜币。'); money=money+10203; api.OnEvent(frames[1],'PLAYER_MONEY'); advance(2); api.OnEvent(frames[1],'CHAT_MSG_MONEY','你获得了5银币。'); api.OnEvent(frames[1],'QUEST_TURNED_IN',103,0,500); money=money+500; api.OnEvent(frames[1],'PLAYER_MONEY'); advance(2)")
        self.totals("assert(totals.loot==10203 and totals.quest==500)")

    def test_delayed_english_loot_evidence_and_grouped_amounts(self):
        self.boot()
        self.run_lua("GOLD_AMOUNT='%d Gold'; SILVER_AMOUNT='%d Silver'; COPPER_AMOUNT='%d Copper'; money=money+12340005; api.OnEvent(frames[1],'PLAYER_MONEY'); advance(0.3); api.OnEvent(frames[1],'CHAT_MSG_MONEY','You loot 1,234 Gold, 5 Copper.'); advance(2)")
        self.totals("assert(totals.loot==12340005)")

    def test_invalid_income_amounts_are_rejected(self):
        self.run_lua("for _,value in ipairs({-1,0.5,math.huge,0/0}) do assert(not api.Income.Valid({startedAt=time(),totals={loot=value}})) end; assert(not api.Income.Valid({startedAt='bad',totals={}})); assert(not api.Income.Valid({startedAt=time(),totals={unknown=1}}))")

    def test_logout_flushes_pending_without_reading_zero_and_preserves_backup(self):
        self.boot()
        self.run_lua("money=money+123; api.OnEvent(frames[1],'PLAYER_MONEY'); money=0; api.OnEvent(frames[1],'PLAYER_LOGOUT'); advance(5); api.OnEvent(frames[1],'PLAYER_MONEY')")
        self.totals("assert(totals.other==123 and GoldTargetTrackerBackup.incomeSources.totals.other==123)")
        self.run_lua("money=5000000; api.OnEvent(frames[1],'PLAYER_LOGIN'); api.OnEvent(frames[1],'PLAYER_ENTERING_WORLD'); advance(3)")
        self.totals("assert(totals.other==123)")

    def test_reset_today_preserves_cumulative_and_reset_all_discards_pending(self):
        self.boot()
        self.run_lua("money=money+123; api.OnEvent(frames[1],'PLAYER_MONEY'); advance(2); api.ResetStatData()")
        self.totals("assert(totals.other==123)")
        self.run_lua("money=money+456; api.OnEvent(frames[1],'PLAYER_MONEY'); setDay('2026-10-26'); api.ResetAllData(); advance(3)")
        self.totals("assert(next(totals)==nil and db.incomeSources.startedAt==time())")

    def test_invalid_income_save_and_source_only_backup_conflict(self):
        self.run_lua("GoldTargetTrackerData={incomeSources={startedAt=time(),totals={vendor=-1}}}; GoldTargetTrackerBackup={}; local original=GoldTargetTrackerData; assert(not api.InitDB()); assert(GoldTargetTrackerData==original)")
        self.run_lua("GoldTargetTrackerData={}; GoldTargetTrackerBackup={incomeSources={startedAt=time(),totals={loot=123}}}; local backup=GoldTargetTrackerBackup; assert(not api.InitDB()); assert(GoldTargetTrackerBackup==backup)")

    def test_valid_income_restore_and_backup_independence(self):
        self.run_lua("GoldTargetTrackerBackup={incomeSources={startedAt=time()-100,totals={loot=123}}}; assert(api.InitDB()); db=GoldTargetTrackerData; assert(db.incomeSources.totals.loot==123); db.incomeSources.totals.loot=456; assert(GoldTargetTrackerBackup.incomeSources.totals.loot==123)")

    def test_income_ui_navigation_empty_money_and_percentages(self):
        self.boot()
        self.run_lua("local incomeButton; for _,f in ipairs(frames) do if f.label and f.label:GetText()=='金币来源' then incomeButton=f end end; assert(incomeButton); incomeButton.scripts.OnClick(); local emptyFound=false; for _,f in ipairs(frames) do if f.text=='尚无收入；获得金币后自动累计，旧历史无法追溯。' then assert(f:IsVisible()); emptyFound=true end end; assert(emptyFound); money=money+12345; api.OnEvent(frames[1],'PLAYER_MONEY'); advance(2); local moneyFound,percentFound=false,false; for _,f in ipairs(frames) do if f:IsVisible() then if f.text=='1 金 23 银 45 铜' then moneyFound=true end; if f.text=='100.00%' then percentFound=true end end end; assert(moneyFound and percentFound)")


if __name__ == '__main__':
    import unittest
    unittest.main()
