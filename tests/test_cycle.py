"""Integrated configuration, saved-data, secure-target and UI contract tests."""
import unittest
from pathlib import Path
import test_addon

class CycleTests(unittest.TestCase):
    setUp = test_addon.AddonTests.setUp
    boot = test_addon.AddonTests.boot
    run_lua = test_addon.AddonTests.run_lua

    def start(self):
        self.boot()
        self.run_lua("""
            cycle=addon.Cycle; cfg=GoldTargetTrackerCycleData
            function press() cycle.button.scripts.PreClick(cycle.button,'LeftButton',false) end
            function done() cycle:OnEvent('UPDATE_TRADESKILL_CAST_STOPPED'); now=now+1 end
            function target() return cycle.button:GetAttribute('target-slot') end
            C_Item.GetItemInfo=function(id) return '物品'..id end
        """)

    def test_defaults_and_money_history_preserved(self):
        self.run_lua("GoldTargetTrackerData={target=7000000,firstTotal=100,accountBase=true,records={['2026-10-20']=100},roles={Realm={Alt={gold=50}}},autoUseItems={'Token'}}")
        self.start()
        self.run_lua("assert(cfg.craft[1].id==1229866 and cfg.disenchant[1].id==245341 and #cfg.recycle==2); assert(db.target==7000000 and db.records['2026-10-20']==100 and db.roles.Realm.Alt.gold==50 and db.autoUseItems[1]=='Token')")

    def test_deleted_and_empty_lists_survive_reload_initialization(self):
        self.run_lua("GoldTargetTrackerCycleData={version=1,enabled=false,recycle={},craft={},disenchant={}}")
        self.start()
        self.run_lua("assert(#cfg.recycle==0 and #cfg.craft==0 and #cfg.disenchant==0 and not cfg.enabled); press(); assert(#craftCalls==0 and not target())")

    def test_bad_cycle_data_does_not_replace_money_or_config(self):
        self.run_lua("GoldTargetTrackerCycleData={version=1,enabled=true,recycle='bad'}; original=GoldTargetTrackerCycleData; GoldTargetTrackerData={firstTotal=123,accountBase=true,target=7000000}")
        self.start()
        self.run_lua("assert(not cycle.data and cfg==original and db.firstTotal==123 and db.target==7000000); press(); assert(#craftCalls==0)")

    def test_list_validation_rejects_corrupt_entries(self):
        self.start()
        self.run_lua("""
            for _,bad in ipairs({-1,0,1.5,math.huge,'245341'}) do
                local d=cycle:NewData(); d.disenchant[1].id=bad; assert(not cycle:Valid(d))
            end
            local d=cycle:NewData(); d.disenchant[2]=d.disenchant[1]; assert(not cycle:Valid(d))
            d=cycle:NewData(); d.recycle[4]={id=1,name='hole'}; assert(not cycle:Valid(d))
        """)

    def test_add_remove_material_immediately_controls_runtime(self):
        self.start()
        self.run_lua("""
            assert(cycle:Add('recycle','item:777:0:0')); assert(#cfg.recycle==3)
            setItem(0,1,25,777); press(); assert(craftCalls[1][1]=='recycle' and craftCalls[1][3]==5)
            done(); assert(cycle:Remove('recycle',3)); cfg.craft={}; press(); assert(#craftCalls==1)
        """)

    def test_eligibility_duplicate_cache_and_capacity_checks(self):
        self.start()
        self.run_lua("""
            assert(not cycle:Add('recycle','239700')); assert(not cycle:Add('recycle','778'))
            local original=C_Item.GetItemInfo; C_Item.GetItemInfo=function() return nil end
            assert(not cycle:Add('disenchant','778')); C_Item.GetItemInfo=original
            for i=2,20 do cfg.disenchant[i]={id=10000+i,name='x'} end
            assert(not cycle:Add('disenchant','778') and #cfg.disenchant==20)
            assert(not cycle:Add('disenchant','0') and not cycle:Add('disenchant','') and not cycle:Add('disenchant','1.2'))
        """)

    def test_craft_add_only_learned_item_recipes(self):
        self.start()
        self.run_lua("""
            assert(cycle:Add('craft','888')); assert(not cycle:Add('craft','1229930'))
            assert(not cycle:Add('craft','999999'))
            for _,key in ipairs({'isRecraft','isEnchantingRecipe','isGatheringRecipe','isDummyRecipe','disabled'}) do
                cycleRecipes[889]={name='x',learned=true,profession=202}; cycleRecipes[889][key]=true
                assert(not cycle:Add('craft','889'),key)
            end
            cycleRecipes[889]={name='x',learned=true,profession=333}; assert(not cycle:Add('craft','889'))
            cycleRecipes[889]={name='x',learned=false,profession=202}; assert(not cycle:Add('craft','889'))
        """)

    def test_manufacturing_does_not_extend_disenchant_list(self):
        self.start()
        self.run_lua("assert(cycle:Add('craft','888')); assert(#cfg.disenchant==1 and cfg.disenchant[1].id==245341)")

    def test_priority_and_skipping_unavailable_recipe(self):
        self.start()
        self.run_lua("""
            cfg.craft={{id=999999,name='unknown'},{id=888,name='second'}}
            press(); assert(craftCalls[1][1]=='craft' and craftCalls[1][2]==888 and craftCalls[1][3]==5)
            done(); cycleRecipes[888].count=0; cfg.craft[3]={id=1229866,name='wrist'}
            press(); assert(craftCalls[2][2]==1229866)
        """)

    def test_disenchant_only_whitelist_and_removal(self):
        self.start()
        self.run_lua("""
            assert(cycle:Add('disenchant','999')); setItem(0,1,1,888); setItem(0,2,1,999)
            press(); assert(target()==2 and cycle.button:GetAttribute('spell')==13262)
            now=now+1; assert(cycle:Remove('disenchant',2)); cfg.craft={}; press(); assert(not target())
        """)

    def test_whitelist_order_over_bag_order(self):
        self.start()
        self.run_lua("""
            cfg.disenchant={{id=999,name='first'},{id=245341,name='second'}}
            setItem(0,1,1,245341); setItem(0,2,1,999); press(); assert(target()==2)
        """)

    def test_high_slots_partial_stacks_and_locked_items(self):
        self.start()
        self.run_lua("""
            C_Container.GetContainerNumSlots=function() return 50 end
            setItem(0,1,4,239700); setItem(0,2,50,239701,'x',true); setItem(5,45,997,239701)
            press(); local c=craftCalls[1]; assert(c[1]=='recycle' and c[3]==199 and c[4]==5 and c[5]==45)
        """)

    def test_batch_gaps_no_duplicate_and_complete_cycle(self):
        self.start()
        self.run_lua("""
            setItem(0,1,10,239701); press(); press(); assert(#craftCalls==1)
            now=1; cycle:OnEvent('UNIT_SPELLCAST_STOP','player'); now=2; press(); assert(#craftCalls==1)
            setItem(0,1,0); done(); press(); assert(#craftCalls==2 and craftCalls[2][1]=='craft')
            setItem(0,1,1,245341); done(); press(); assert(target()==1)
            setItem(0,1,0); now=now+1; press(); assert(#craftCalls==3 and craftCalls[3][1]=='craft')
        """)

    def test_casting_loot_and_cursor_pause(self):
        self.start()
        self.run_lua("""
            setItem(0,1,1,245341)
            cycleCasting=true; press(); assert(not target()); cycleCasting=false
            cursorType='item'; press(); assert(not target()); cursorType=nil
            spellCursor=true; press(); assert(not target()); spellCursor=false
            cycle:OnEvent('LOOT_OPENED'); press(); assert(not target()); cycle:OnEvent('LOOT_CLOSED')
            press(); assert(not target()); now=1; press(); assert(target()==1)
        """)

    def test_deferred_engine_open_and_bag_room(self):
        self.start()
        self.run_lua("""
            cycleFree=2; press(); assert(#craftCalls==0)
            cycleFree=5; cycleProfession=false; press(); assert(craftCalls[1][1]=='open')
            cycleProfession=202; now=1; press(); assert(craftCalls[2][3]==3)
        """)

    def test_no_change_mid_cast_or_combat(self):
        self.start()
        self.run_lua("""
            press(); assert(not cycle:Remove('craft',1) and not cycle:Add('disenchant','999'))
            done(); combat=true; assert(not cycle:Remove('craft',1)); combat=false
            assert(cycle:Remove('craft',1) and #cfg.craft==0)
        """)

    def test_pause_and_all_empty_lists_no_action(self):
        self.start()
        self.run_lua("""
            assert(cycle:SetEnabled(false)); setItem(0,1,1,245341); press(); assert(not target())
            cfg.disenchant={}; cfg.craft={}; cfg.recycle={}; assert(cycle:SetEnabled(true)); press()
            assert(#craftCalls==0 and not target())
        """)

    def test_macro_reuse_conflict_and_capacity(self):
        self.start()
        self.run_lua("""
            cycle:OnEvent('PLAYER_LOGIN'); cycle:OnEvent('PLAYER_LOGIN'); assert(macroCalls==1)
            macros['安迪循环'].body='/say keep'; cycle:EnsureMacro(); assert(macros['安迪循环'].body=='/say keep')
            macros={}; macroCount=30; cycle:EnsureMacro(); assert(macroCalls==1)
            macroCount=0; macroError=true; cycle:EnsureMacro(); assert(macroCalls==1)
        """)

    def test_macro_combat_deferral(self):
        self.start()
        self.run_lua("combat=true; cycle:OnEvent('PLAYER_LOGIN'); assert(macroCalls==0); combat=false; cycle:OnEvent('PLAYER_REGEN_ENABLED'); assert(macroCalls==1)")

    def test_legacy_button_takeover_and_existing_macro_survive(self):
        self.run_lua("""
            old=CreateFrame('Button','AndyCraftCycleButton',UIParent)
            old:RegisterEvent('PLAYER_LOGIN'); old:SetScript('OnEvent',function() error('old event still active') end)
            old:SetScript('PreClick',function() error('old click still active') end)
            macros['安迪循环']={body='/stopmacro [combat]\\n/click AndyCraftCycleButton'}
        """)
        self.start()
        self.run_lua("assert(cycle.button==old and next(old.events)==nil and not old.scripts.OnEvent); cycle:EnsureMacro(); assert(macroCalls==0); press(); assert(#craftCalls==1)")

    def test_actual_legacy_011_load_order_and_takeover(self):
        legacy=Path(__file__).resolve().parents[3] / 'AndyCraftCycle' / 'AndyCraftCycle' / 'AndyCraftCycle.lua'
        if not legacy.exists(): self.skipTest('optional local 0.1.1 compatibility fixture unavailable')
        self.lua.execute(legacy.read_text(encoding='utf-8'))
        self.start()
        self.run_lua("assert(not cycle.button.scripts.OnEvent and next(cycle.button.events)==nil); press(); assert(#craftCalls==1)")

    def test_ui_add_drag_remove_and_current_recipe(self):
        self.start()
        self.run_lua("""
            local r=cycle.ui.cards.recycle
            cursorType='item'; cursorID=777; r.input.scripts.OnReceiveDrag(); assert(r.input:GetText()=='777' and not cursorType)
            r.add.scripts.OnClick(); assert(#cfg.recycle==3 and r.rows[3]:IsShown())
            r.rows[3].remove.scripts.OnClick(); assert(#cfg.recycle==2 and not r.rows[3]:IsShown())
            ProfessionsFrame={CraftingPage={GetRecipeInfo=function() return {recipeID=888} end}}
            cycle.ui.cards.craft.current.scripts.OnClick(); assert(#cfg.craft==2)
        """)

    def test_ui_middle_remove_then_remove_updated_row(self):
        self.start()
        self.run_lua("""
            assert(cycle:Add('recycle','777')); local r=cycle.ui.cards.recycle
            r.rows[2].remove.scripts.OnClick(); assert(cfg.recycle[2].id==777)
            r.rows[2].remove.scripts.OnClick(); assert(#cfg.recycle==1 and not r.rows[2]:IsShown())
        """)

    def test_ui_responsive_scroll_and_readable_text(self):
        self.start()
        self.run_lua("""
            local page=GoldTargetTrackerCyclePage
            for _,width in ipairs({604,400,320}) do
                page:SetSize(width,450); assert(page.content:GetWidth()<=width)
                assert(page.content:GetHeight()>450 and page:GetScale()==1)
                for _,c in pairs(cycle.ui.cards) do
                    assert(c.frame:GetWidth()<=width and c.frame:GetHeight()>140)
                    assert(c.input.points.TOPRIGHT and c.help.wordWrap)
                    for _,r in ipairs(c.rows) do assert(r.label.font[2]>=14 and r.remove:GetFontString().font[2]>=14) end
                end
            end
        """)

    def test_manifest_has_character_storage_and_legacy_order(self):
        toc=(test_addon.ROOT/'GoldTargetTracker/GoldTargetTracker.toc').read_text(encoding='utf-8')
        self.assertIn('## SavedVariablesPerCharacter: GoldTargetTrackerCycleData',toc)
        self.assertIn('## OptionalDeps: AndyCraftCycle',toc)
        self.assertLess(toc.index('CycleLists.lua'),toc.index('ProfessionCycle.lua'))
        self.assertLess(toc.index('CycleSettings.lua'),toc.index('GoldTargetTracker.lua'))

if __name__=='__main__': unittest.main()
