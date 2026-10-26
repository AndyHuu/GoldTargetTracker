"""Run: python tests/test_addon.py (uses project-local lupa==2.6, Lua 5.1)."""
from pathlib import Path
import sys
import unittest

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / '.tools' / 'python'))
from lupa.lua51 import LuaRuntime

EXPORTS = '''
return {InitDB=InitDB, ValidData=ValidData, SyncBackup=SyncBackup, CopyData=CopyData,
GetTotalGold=GetTotalGold, GetNaturalDailyAvg=GetNaturalDailyAvg, GetRecent7DayData=GetRecent7DayData,
DayOrdinal=DayOrdinal, GetAllRoleRows=GetAllRoleRows, OnEvent=OnEvent,
SnapshotBags=SnapshotBags, TryAutoUseItems=TryAutoUseItems, ProcessAutoUseQueue=ProcessAutoUseQueue,
ResetAchievementBaseline=ResetAchievementBaseline, CheckAchievementCrossing=CheckAchievementCrossing,
TogglePanel=TogglePanel, ResetStatData=ResetStatData, ResetAllData=ResetAllData,
GetAutoUseContent=function() return autoUseContent end,
GetTodayGain=GetTodayGain, Income=Income, GetMainContent=function() return contentInstances[1] end}
'''


class AddonTests(unittest.TestCase):
    def setUp(self):
        self.lua = LuaRuntime(unpack_returned_tuples=True)
        self.lua.execute((ROOT / 'tests' / 'wow_mock.lua').read_text(encoding='utf-8'))
        self.lua.execute("addon={}")
        income = (ROOT / 'GoldTargetTracker' / 'IncomeSources.lua').read_text(encoding='utf-8-sig')
        self.lua.execute(income, 'GoldTargetTracker', self.lua.globals().addon)
        self.lua.globals().source = (ROOT / 'GoldTargetTracker' / 'GoldTargetTracker.lua').read_text(encoding='utf-8-sig') + EXPORTS
        self.lua.execute("api=assert(loadstring(source, '@GoldTargetTracker.lua'))('GoldTargetTracker',addon)")

    def run_lua(self, body):
        self.lua.execute(body)

    def init(self):
        self.run_lua("assert(api.InitDB()); db=GoldTargetTrackerData")

    def boot(self):
        self.run_lua("api.OnEvent(frames[1], 'ADDON_LOADED', 'GoldTargetTracker'); api.OnEvent(frames[1], 'PLAYER_LOGIN'); api.OnEvent(frames[1], 'PLAYER_ENTERING_WORLD'); db=GoldTargetTrackerData")

    def test_settings_load_has_no_swallowed_ui_errors(self):
        self.boot()
        self.run_lua("for _,m in ipairs(messages) do assert(not m:find('错误'),m) end; assert(GoldTargetTrackerSettingsPanel); assert(GoldTargetTrackerFrame.width==500 and GoldTargetTrackerFrame.height==64)")

    def test_chart_has_seven_points_per_series_and_only_two_tooltip_values(self):
        self.boot()
        self.run_lua("local dots,lines=0,0; for _,f in ipairs(frames) do if f.kind=='Line' then lines=lines+1; assert(f.start) end; if f.pointData then dots=dots+1; f.scripts.OnEnter(f); assert(#GameTooltip.tooltipRows==2 and GameTooltip.tooltipRows[1][1]=='当日收益' and GameTooltip.tooltipRows[2][1]=='当日总金币') end end; assert(dots==14 and lines==12)")

    def test_role_expansion_keeps_total_unchanged(self):
        self.boot()
        self.run_lua("for _,f in ipairs(frames) do if f.label and f.label:GetText()=='金币来源' then f.scripts.OnClick() end end; for i=1,8 do db.roles.Realm['Alt'..i]={gold=i} end; money=1000000; api.OnEvent(frames[1],'PLAYER_MONEY'); local total=api.GetTotalGold(); local function countRows() local n=0; for _,f in ipairs(frames) do if type(f.name)=='table' and type(f.gold)=='table' and f:IsVisible() then n=n+1 end end; return n end; assert(countRows()==5); clickText('展开全部'); assert(countRows()==9 and api.GetTotalGold()==total); clickText('收起列表'); assert(countRows()==5 and api.GetTotalGold()==total)")

    def test_old_save_and_backup_independence(self):
        self.run_lua("GoldTargetTrackerData={target=7000000,name='Custom',records={['2026-10-20']=110},hourly={['2026-10-20 12']=110},firstTotal=100,accountBase=true,roles={Realm={Alt={gold=40,pos={point='CENTER',x=1,y=2}}}},autoUseItems={'Token'},pos={point='CENTER',x=10,y=20},hidePanelInCombat=false}")
        self.init()
        self.run_lua("assert(db.target==7000000 and db.name=='Custom' and db.firstTotal==100 and db.records['2026-10-20']==110 and db.hourly['2026-10-20 12']==110 and db.roles.Realm.Alt.pos.x==1 and db.pos.x==10 and db.autoUseItems[1]=='Token' and db.hidePanelInCombat==false); db.records['2026-10-20']=999; assert(GoldTargetTrackerBackup.records['2026-10-20']==110)")

    def test_save_conflict_preserves_both(self):
        self.run_lua("GoldTargetTrackerData={target=5}; GoldTargetTrackerBackup={records={['2026-10-20']=110}}; local main,backup=GoldTargetTrackerData,GoldTargetTrackerBackup; assert(not api.InitDB()); assert(GoldTargetTrackerData==main and GoldTargetTrackerBackup==backup)")

    def test_invalid_save_preserved_without_valid_recovery(self):
        self.run_lua("GoldTargetTrackerData={records='broken'}; GoldTargetTrackerBackup={}; local main,backup=GoldTargetTrackerData,GoldTargetTrackerBackup; assert(not api.InitDB()); assert(GoldTargetTrackerData==main and GoldTargetTrackerBackup==backup)")

    def test_account_bank_counted_once_and_unknown_zero_preserved(self):
        self.init()
        self.run_lua("db.roles={Realm={PlayerOne={gold=999,bank=200,date='2026-10-24 12:00'},Alt={gold=50,bank=200,date='2026-10-24 12:00'}}}; assert(api.GetTotalGold()==350); bankReady=true; assert(api.GetTotalGold()==150); bankMoney=3000000; assert(api.GetTotalGold()==450)")

    def test_natural_average_and_continuous_history(self):
        self.init()
        self.run_lua("db.firstTotal=100; db.records={['2026-10-20']=110,['2026-10-25']=160}; money=1600000; local avg,span=api.GetNaturalDailyAvg(); assert(avg==10 and span==6); local rows=api.GetRecent7DayData(); assert(#rows==7 and rows[1].day=='2026-10-19' and rows[7].day=='2026-10-25'); assert(rows[3].gain==0 and rows[3].gold==110 and rows[7].gain==50)")

    def test_history_full_week_single_day_and_zero_gain(self):
        self.init()
        self.run_lua("db.firstTotal=100; for i=19,25 do db.records['2026-10-'..i]=100+(i-18)*10 end; money=1700000; local avg,span=api.GetNaturalDailyAvg(); assert(avg==10 and span==7); for _,r in ipairs(api.GetRecent7DayData()) do assert(r.gain==10) end; db.records={['2026-10-25']=100}; money=1000000; avg,span=api.GetNaturalDailyAvg(); assert(avg==0 and span==1); assert(api.GetRecent7DayData()[7].gain==0)")

    def test_calendar_boundaries(self):
        self.init()
        self.run_lua("assert(api.DayOrdinal('2024-03-01')-api.DayOrdinal('2024-02-29')==1); for _,day in ipairs({'2027-01-03','2026-03-03'}) do setDay(day); local r=api.GetRecent7DayData(); for i=2,7 do assert(api.DayOrdinal(r[i].day)-api.DayOrdinal(r[i-1].day)==1) end end")

    def test_role_order_and_zero_filter(self):
        self.init()
        self.run_lua("db.roles={Realm={PlayerOne={gold=999},Small={gold=5},Big={gold=500},Zero={gold=0}}}; local r=api.GetAllRoleRows(); assert(#r==3 and r[1].name=='PlayerOne' and r[1].gold==100 and r[2].name=='Big' and r[3].name=='Small')")

    def test_combat_restores_only_previously_open_panel(self):
        self.boot()
        self.run_lua("local p=GoldTargetTrackerFrame; p:Show(); combat=true; api.OnEvent(frames[1],'PLAYER_REGEN_DISABLED'); assert(not p:IsShown()); api.TogglePanel(); assert(not p:IsShown()); combat=false; api.OnEvent(frames[1],'PLAYER_REGEN_ENABLED'); assert(p:IsShown()); p:Hide(); combat=true; api.OnEvent(frames[1],'PLAYER_REGEN_DISABLED'); combat=false; api.OnEvent(frames[1],'PLAYER_REGEN_ENABLED'); assert(not p:IsShown())")

    def test_target_change_and_closed_panel_do_not_celebrate(self):
        self.boot()
        self.run_lua("db.target=90; api.CheckAchievementCrossing(100); assert(soundCount==0); db.target=150; api.ResetAchievementBaseline(); GoldTargetTrackerFrame:Hide(); money=1600000; api.CheckAchievementCrossing(160); assert(soundCount==0)")

    def test_crossing_celebrates_once_until_manually_closed(self):
        self.boot()
        self.run_lua("db.target=150; api.ResetAchievementBaseline(); money=1600000; api.CheckAchievementCrossing(160); api.CheckAchievementCrossing(160); assert(soundCount==1); assert(not GoldTargetTrackerFrame:IsShown(), 'main panel did not hide at goal'); advance(20); local toast=GoldTargetTrackerAchievementToast; assert(toast:IsShown(), 'celebration closed automatically'); assert(toast.closeButton and toast.closeButton.scripts.OnClick); toast.closeButton.scripts.OnClick(); assert(not toast:IsShown() and not GoldTargetTrackerFrame:IsShown())")

    def test_deferred_celebration_keeps_crossing_amount(self):
        self.boot()
        self.run_lua("db.target=150; api.ResetAchievementBaseline(); combat=true; api.OnEvent(frames[1],'PLAYER_REGEN_DISABLED'); money=1600000; api.CheckAchievementCrossing(160); money=1700000; api.CheckAchievementCrossing(170); assert(soundCount==0); combat=false; api.OnEvent(frames[1],'PLAYER_REGEN_ENABLED'); assert(soundCount==1 and not GoldTargetTrackerFrame:IsShown()); assert(GoldTargetTrackerAchievementToast.total:GetText():find('160'),GoldTargetTrackerAchievementToast.total:GetText())")

    def test_completed_goal_panel_stays_hidden_after_combat(self):
        self.boot()
        self.run_lua("db.target=150; api.ResetAchievementBaseline(); money=1600000; api.CheckAchievementCrossing(160); combat=true; api.OnEvent(frames[1],'PLAYER_REGEN_DISABLED'); local toast=GoldTargetTrackerAchievementToast; assert(toast.closeButton); toast.closeButton.scripts.OnClick(); combat=false; api.OnEvent(frames[1],'PLAYER_REGEN_ENABLED'); assert(not GoldTargetTrackerFrame:IsShown() and not toast:IsShown()); api.TogglePanel(); assert(GoldTargetTrackerFrame:IsShown())")

    def test_auto_use_page_has_readable_rows_above_background(self):
        self.boot()
        self.run_lua("local c=api.GetAutoUseContent(); assert(c.listScroll and c.listContent, 'missing scroll list'); assert(c.input.font[2]>=14 and c.input.parent==c.listScroll.parent); for _,line in ipairs(c.lines) do assert(line.name.parent==line.removeBtn.parent and line.name.parent==line.row); assert(line.name.font[2]>=14 and line.name.textColor[1]>=0.9) end; local page=c.input.parent.parent; assert(page.parent==GoldTargetTrackerOverviewPage.parent,'auto page not at viewport level'); while page do assert(page:GetScale()==1,'auto page font shrinks'); page=page.parent end")

    def test_auto_use_full_list_scrolls_and_remove_preserves_other_items(self):
        self.run_lua("GoldTargetTrackerData={autoUseItems={}}; for i=1,20 do GoldTargetTrackerData.autoUseItems[i]='Item'..i end")
        self.boot()
        self.run_lua("local c=api.GetAutoUseContent(); assert(c.listContent and c.listScroll,'missing scroll list'); assert(c.listContent:GetHeight()==480 and #c.lines==20); c.listScroll:SetSize(360,300); assert(c.listContent:GetWidth()==360); c.listScroll:SetVerticalScroll(420); c.lines[20].removeBtn.scripts.OnClick(); assert(#db.autoUseItems==19 and db.autoUseItems[19]=='Item19' and not c.lines[20].row:IsShown()); assert(c.listContent:GetHeight()==456 and c.listScroll:GetVerticalScroll()<=156)")

    def test_auto_use_new_layout_adds_disables_and_clears(self):
        self.boot()
        self.run_lua("local c=api.GetAutoUseContent(); c.input:SetText('Token'); clickText('添加'); assert(db.autoUseItems[1]=='Token' and c.lines[1].name:GetText()=='Token'); clickText('停用自动使用'); assert(db.autoUseEnabled==false and db.autoUseItems[1]=='Token'); clickText('启用自动使用'); assert(db.autoUseEnabled==true); clickText('清空'); assert(#db.autoUseItems==0 and c.emptyHint:IsShown() and not c.lines[1].row:IsShown())")

    def test_settings_design_fits_canvas_after_resize(self):
        self.boot()
        self.run_lua("for _,page in ipairs({GoldTargetTrackerOverviewPage,GoldTargetTrackerIncomePage,GoldTargetTrackerOptionsPage}) do assert(page.content and page.scripts.OnSizeChanged); for _,size in ipairs({{460,540},{604,684},{800,800},{320,450}}) do page:SetSize(size[1],size[2]); assert(page.content:GetWidth()<=size[1] and page.content:GetScale()==1, 'page font resized or horizontal overflow'); assert(page:GetScrollChild()==page.content) end end")

    def test_four_tabs_with_combat_control_in_settings(self):
        self.boot()
        self.run_lua("local count,settingsButton,checkbox=0; for _,f in ipairs(frames) do if f.kind=='Button' and type(f.label)=='table' then count=count+1; assert(f.label:GetText()~='界面与显示'); if f.label:GetText()=='设置' then settingsButton=f end end; if f.kind=='CheckButton' then checkbox=f end end; assert(count==4 and settingsButton and checkbox); settingsButton.scripts.OnClick(); assert(checkbox:IsVisible(), 'combat option not on Settings page'); checkbox:SetChecked(false); checkbox.scripts.OnClick(checkbox); assert(db.hidePanelInCombat==false and GoldTargetTrackerBackup.hidePanelInCombat==false)")

    def test_target_presets_update_visible_amount_and_selected_state(self):
        self.boot()
        self.run_lua("local input; for _,f in ipairs(frames) do if f.kind=='EditBox' and f.width==150 and f.height==24 then input=f end end; assert(input); local b700=clickText('700万'); assert(db.target==7000000 and GoldTargetTrackerBackup.target==7000000); assert(input:GetText()=='7000000', 'preset left stale visible input'); assert(not b700:IsEnabled()); local b500=clickText('500万'); assert(db.target==5000000 and input:GetText()=='5000000' and not b500:IsEnabled() and b700:IsEnabled()); input:SetText('6000000'); input.scripts.OnEnterPressed(input); assert(db.target==6000000 and b500:IsEnabled() and b700:IsEnabled() and soundCount==0)")

    def test_panel_context_menu_order_and_defaults(self):
        self.boot()
        self.run_lua("local m=openPanelMenu(); assert(m.owner==GoldTargetTrackerFrame and #m.entries==5); assert(m.entries[1].text=='战斗中隐藏' and m.entries[1].selected()); assert(m.entries[2].text=='锁定窗口' and not m.entries[2].selected()); assert(m.entries[3].text=='小地图图标' and m.entries[3].selected()); assert(m.entries[4].kind=='divider' and m.entries[5].text=='设置')")

    def test_panel_left_click_does_not_open_menu(self):
        self.boot()
        self.run_lua("local p=GoldTargetTrackerFrame; assert(p.scripts.OnMouseUp); p.scripts.OnMouseUp(p,'LeftButton'); assert(not contextMenu); p.scripts.OnDragStart(p); assert(p.moving)")

    def test_panel_lock_prevents_drag_but_allows_right_click(self):
        self.boot()
        self.run_lua("local p=GoldTargetTrackerFrame; openPanelMenu(); menuEntry('锁定窗口').callback(); assert(db.lockPanel and GoldTargetTrackerBackup.lockPanel and p.movable==false); p.scripts.OnDragStart(p); assert(not p.moving); p.scripts.OnDragStop(p); assert(not db.roles.Realm.PlayerOne.pos); openPanelMenu(); menuEntry('锁定窗口').callback(); assert(not db.lockPanel and p.movable); p.scripts.OnDragStart(p); assert(p.moving and p.moveCalls==1); p.scripts.OnDragStop(p); assert(db.roles.Realm.PlayerOne.pos)")

    def test_minimap_toggle_persists_and_can_be_reenabled(self):
        self.boot()
        self.run_lua("openPanelMenu(); local option=menuEntry('小地图图标'); option.callback(); assert(not db.showMinimapIcon and not GoldTargetTrackerBackup.showMinimapIcon and not GoldTargetTrackerMinimapButton:IsShown()); GoldTargetTrackerFrame:Hide(); api.TogglePanel(); assert(GoldTargetTrackerFrame:IsShown()); openPanelMenu(); option=menuEntry('小地图图标'); assert(not option.selected()); option.callback(); assert(db.showMinimapIcon and GoldTargetTrackerMinimapButton:IsShown())")

    def test_menu_combat_toggle_stays_in_sync_with_settings(self):
        self.boot()
        self.run_lua("local checkbox; for _,f in ipairs(frames) do if f.kind=='CheckButton' then checkbox=f end end; openPanelMenu(); menuEntry('战斗中隐藏').callback(); assert(db.hidePanelInCombat==false and checkbox:GetChecked()==false and GoldTargetTrackerBackup.hidePanelInCombat==false); checkbox:SetChecked(true); checkbox.scripts.OnClick(checkbox); openPanelMenu(); assert(menuEntry('战斗中隐藏').selected())")

    def test_menu_combat_toggle_applies_immediately_during_combat(self):
        self.run_lua("GoldTargetTrackerData={hidePanelInCombat=false}")
        self.boot()
        self.run_lua("combat=true; api.OnEvent(frames[1],'PLAYER_REGEN_DISABLED'); openPanelMenu(); menuEntry('战斗中隐藏').callback(); assert(not GoldTargetTrackerFrame:IsShown()); combat=false; api.OnEvent(frames[1],'PLAYER_REGEN_ENABLED'); assert(GoldTargetTrackerFrame:IsShown())")

    def test_menu_settings_button_opens_plugin_settings_tab(self):
        self.boot()
        self.run_lua("openPanelMenu(); menuEntry('设置').callback(); assert(openedSettingsCategory==1); local checkbox; for _,f in ipairs(frames) do if f.kind=='CheckButton' then checkbox=f end end; assert(checkbox:IsVisible(), 'settings navigation did not select Settings tab')")

    def test_edit_box_font_flags_allow_settings_registration(self):
        self.boot()
        self.run_lua("for _,msg in ipairs(messages) do assert(not msg:find('创建设置面板错误'),msg) end; local c=api.GetAutoUseContent(); assert(c and c.input.font[3]==''); openPanelMenu(); menuEntry('设置').callback(); assert(openedSettingsCategory==1)")

    def test_forecast_survives_character_switch_with_same_account_balance(self):
        self.run_lua("money=500*10000; GoldTargetTrackerData={accountBase=true,firstTotal=1000,records={['2026-10-24']=1000},hourly={['2026-10-25 10']=1100},roles={Realm={PlayerOne={gold=500},Alt={gold=600}}}}")
        self.boot()
        self.run_lua("local before=api.GetMainContent().txtAvgHour:GetText(); assert(api.GetTotalGold()==1100 and api.GetTodayGain()==100 and before:find('剩余')); money=0; api.OnEvent(frames[1],'PLAYER_LOGOUT'); GoldTargetTrackerData=api.CopyData(GoldTargetTrackerBackup); assert(api.InitDB()); playerName='Alt'; money=600*10000; api.OnEvent(frames[1],'PLAYER_LOGIN'); assert(api.GetTotalGold()==1100 and api.GetTodayGain()==100, 'logout zero overwrote previous character balance'); assert(api.GetMainContent().txtAvgHour:GetText()==before, 'character switch lost account forecast')")

    def test_logout_preserves_snapshots_when_money_api_clears(self):
        self.run_lua("money=1100*10000; GoldTargetTrackerData={accountBase=true,firstTotal=1000}")
        self.boot()
        self.run_lua("money=0; api.OnEvent(frames[1],'PLAYER_LOGOUT'); api.OnEvent(frames[1],'PLAYER_MONEY'); for _,f in ipairs(frames) do if f.scripts.OnUpdate then f.scripts.OnUpdate(f,1) end end; advance(5); assert(db.roles.Realm.PlayerOne.gold==1100 and db.records['2026-10-25']==1100 and db.hourly['2026-10-25 12']==1100, 'logout wrote transient zero'); assert(GoldTargetTrackerBackup.roles.Realm.PlayerOne.gold==1100)")

    def test_real_zero_balance_is_saved_before_logout(self):
        self.boot()
        self.run_lua("money=0; api.OnEvent(frames[1],'PLAYER_MONEY'); assert(db.roles.Realm.PlayerOne.gold==0 and db.records['2026-10-25']==0); api.OnEvent(frames[1],'PLAYER_LOGOUT'); assert(GoldTargetTrackerBackup.roles.Realm.PlayerOne.gold==0)")

    def test_forecast_explains_nonpositive_daily_gain(self):
        self.run_lua("money=1200000*10000; GoldTargetTrackerData={accountBase=true,firstTotal=1234567,todayBase={day='2026-10-25',gold=1234567}}")
        self.boot()
        self.run_lua("assert(api.GetTodayGain()==-34567); assert(api.GetMainContent().txtAvgHour:GetText()=='今日暂无正收益'); playerName='Alt'; money=0; db.roles.Realm.PlayerOne.gold=1200000; api.OnEvent(frames[1],'PLAYER_LOGIN'); assert(api.GetTodayGain()==-34567 and api.GetMainContent().txtAvgHour:GetText()=='今日暂无正收益')")

    def test_forecast_explains_zero_elapsed_time_then_recovers(self):
        self.run_lua("money=1100*10000; GoldTargetTrackerData={accountBase=true,firstTotal=1000}")
        self.boot()
        self.run_lua("assert(api.GetTodayGain()==100 and api.GetMainContent().txtAvgHour:GetText()=='正在采集时长'); local originalTime=time; time=function(value) return value and originalTime(value) or originalTime()+1 end; api.OnEvent(frames[1],'PLAYER_MONEY'); assert(api.GetMainContent().txtAvgHour:GetText():find('剩余'))")

    def test_menu_settings_during_combat_does_not_open_protected_panel(self):
        self.boot()
        self.run_lua("combat=true; openPanelMenu(); menuEntry('设置').callback(); assert(not openedSettingsCategory)")

    def test_window_options_restore_from_saved_variables(self):
        self.run_lua("GoldTargetTrackerData={lockPanel=true,showMinimapIcon=false,hidePanelInCombat=false}")
        self.boot()
        self.run_lua("assert(db.lockPanel and db.showMinimapIcon==false and db.hidePanelInCombat==false); assert(GoldTargetTrackerFrame.movable==false and not GoldTargetTrackerMinimapButton:IsShown()); assert(GoldTargetTrackerBackup.lockPanel and GoldTargetTrackerBackup.showMinimapIcon==false)")

    def test_invalid_window_options_pause_without_overwriting(self):
        self.run_lua("for _,key in ipairs({'lockPanel','showMinimapIcon'}) do local data={[key]='yes'}; assert(not api.ValidData(data)); GoldTargetTrackerData=data; GoldTargetTrackerBackup=nil; assert(not api.InitDB() and GoldTargetTrackerData==data) end")

    def test_near_goal_never_rounds_up_to_complete(self):
        self.boot()
        self.run_lua("for _,gap in ipairs({500,100,1}) do money=(5000000-gap)*10000; api.OnEvent(frames[1],'PLAYER_MONEY'); assertPercentLabels('99.99%','99.99%'); assert(soundCount==0) end")

    def test_percent_truncates_to_two_decimal_places(self):
        self.boot()
        self.run_lua("money=1234567*10000; api.OnEvent(frames[1],'PLAYER_MONEY'); assertPercentLabels('24.69%','24.69%')")

    def test_percent_exact_boundaries_and_real_completion(self):
        self.boot()
        self.run_lua("for _,row in ipairs({{0,'0.00%'},{1250000,'25.00%'},{4999000,'99.98%'},{5000000,'100.00%'}}) do money=row[1]*10000; api.OnEvent(frames[1],'PLAYER_MONEY'); assertPercentLabels(row[2],row[2]) end; assert(soundCount==1)")

    def test_percent_over_target_preserves_existing_cap_rules(self):
        self.boot()
        self.run_lua("money=5250000*10000; api.OnEvent(frames[1],'PLAYER_MONEY'); assertPercentLabels('100.00%','105.00%')")

    def test_acquisition_increment_moves_and_mixed_changes(self):
        self.init()
        self.run_lua("db.autoUseItems={'Token'}; setItem(0,1,5); api.SnapshotBags(); setItem(0,1,7); api.TryAutoUseItems(); assert(db.autoUseQueue[1].count==2); db.autoUseQueue={}; setItem(0,1,nil); setItem(0,2,7); api.TryAutoUseItems(); assert(#db.autoUseQueue==0); setItem(0,2,3); setItem(0,3,4); api.TryAutoUseItems(); assert(#db.autoUseQueue==0); setItem(0,2,nil); setItem(0,3,8); api.TryAutoUseItems(); assert(#db.autoUseQueue==0)")

    def test_reagent_bag_is_scanned(self):
        self.init()
        self.run_lua("db.autoUseItems={'Token'}; api.SnapshotBags(); setItem(5,1,2); api.TryAutoUseItems(); assert(#db.autoUseQueue==1 and db.autoUseQueue[1].count==2); advance(1.5); assert(#uses==2 and #db.autoUseQueue==0)")

    def test_queue_pauses_on_combat_lock_cooldown_and_interactions(self):
        self.init()
        self.run_lua("db.autoUseItems={'Token'}; api.SnapshotBags(); combat=true; setItem(0,1,2); api.TryAutoUseItems(); advance(1); assert(#uses==0 and db.autoUseQueue[1].count==2); combat=false; cooling=true; api.ProcessAutoUseQueue(); advance(2); assert(#uses==0); cooling=false; bags[0][1].isLocked=true; advance(2); assert(#uses==0); bags[0][1].isLocked=false; MailFrame=CreateFrame('Frame'); advance(2); assert(#uses==0); MailFrame:Hide(); advance(4); assert(#uses==2 and #db.autoUseQueue==0)")

    def test_multi_unit_consumption_does_not_use_old_inventory(self):
        self.init()
        self.run_lua("db.autoUseItems={'Token'}; setItem(0,1,5); api.SnapshotBags(); setItem(0,1,7); consumeCount=2; api.TryAutoUseItems(); advance(3); assert(#uses==1 and bags[0][1].stackCount==5, 'consumed pre-existing inventory')")

    def test_reload_inflight_reconciles_all_consumed_units(self):
        self.init()
        self.run_lua("db.autoUseItems={'Token'}; setItem(0,1,5); db.autoUseQueue={{itemID=1,name='Token',count=2,inFlight=true,beforeCount=7}}; api.ProcessAutoUseQueue(); advance(1); assert(#uses==0 and #db.autoUseQueue==0, 'reload repeated consumed units')")

    def test_acquisition_during_confirmation_does_not_consume_old_inventory(self):
        self.init()
        self.run_lua("db.autoUseItems={'Token'}; setItem(0,1,5); api.SnapshotBags(); setItem(0,1,6); api.TryAutoUseItems(); advance(0.2); api.TryAutoUseItems(); setItem(0,1,7); api.TryAutoUseItems(); advance(4); assert(#uses==3 and bags[0][1].stackCount==5, 'in-flight acquisition consumed old inventory')")

    def test_queue_reload_and_logout_rules(self):
        self.boot()
        self.run_lua("db.autoUseQueue={{itemID=1,name='Token',count=2}}; ReloadUI(); api.OnEvent(frames[1],'PLAYER_LOGOUT'); assert(db.autoUseQueuePendingReload and #db.autoUseQueue==1); api.OnEvent(frames[1],'PLAYER_LOGIN'); assert(not db.autoUseQueuePendingReload and #db.autoUseQueue==1)")

    def test_normal_logout_clears_queue(self):
        self.boot()
        self.run_lua("db.autoUseQueue={{itemID=1,name='Token',count=2}}; api.OnEvent(frames[1],'PLAYER_LOGOUT'); assert(#db.autoUseQueue==0 and not db.autoUseQueuePendingReload)")

    def test_unconfirmed_use_preserves_task_and_waits_for_context_change(self):
        self.init()
        self.run_lua("db.autoUseItems={'Token'}; api.SnapshotBags(); setItem(0,1,2); consumeCount=0; api.TryAutoUseItems(); advance(10); assert(#uses==3 and #db.autoUseQueue==1 and db.autoUseQueue[1].count==2, 'unconfirmed use discarded task'); consumeCount=1; api.OnEvent(frames[1],'MAIL_CLOSED'); advance(4); assert(#db.autoUseQueue==0 and #uses==5)")

    def test_lua_errors_preserve_queue_without_endless_calls(self):
        self.init()
        self.run_lua("db.autoUseItems={'Token'}; api.SnapshotBags(); setItem(0,1,1); useError=true; api.TryAutoUseItems(); advance(10); assert(#uses==3 and db.autoUseQueue[1].count==1, 'unbounded Lua error retries')")

    def test_delayed_item_name_is_verified_before_use(self):
        self.init()
        self.run_lua("db.autoUseItems={'Token'}; api.SnapshotBags(); setItem(0,1,1); bags[0][1].itemName=nil; api.TryAutoUseItems(); advance(1); assert(#uses==0 and #db.autoUseQueue==1); itemInfoName='Other'; advance(3); assert(#uses==0 and #db.autoUseQueue==0)")

    def test_long_cooldown_retains_task_until_ready(self):
        self.init()
        self.run_lua("db.autoUseItems={'Token'}; api.SnapshotBags(); setItem(0,1,1); cooling=true; api.TryAutoUseItems(); advance(10); assert(#uses==0 and db.autoUseQueue[1].count==1); cooling=false; advance(3); assert(#uses==1 and #db.autoUseQueue==0)")

    def test_invalid_queue_fields_rejected(self):
        self.run_lua("assert(not api.ValidData({autoUseQueue={{itemID=1,count=0/0}}})); assert(not api.ValidData({hidePanelInCombat='yes'}))")

    def test_empty_pending_task_never_uses_inventory(self):
        self.init()
        self.run_lua("db.autoUseItems={'Token'}; setItem(0,1,5); db.autoUseQueue={{itemID=1,name='Token',count=0}}; api.ProcessAutoUseQueue(); advance(1); assert(#uses==0 and #db.autoUseQueue==0, 'zero task used inventory')")

    def test_resets_require_popup_and_preserve_assets(self):
        self.boot()
        self.run_lua("db.records['2026-10-20']=90; local roles=db.roles; clickText('重置所有'); assert(lastPopup=='GOLDTT_RESET_ALL' and db.records['2026-10-20']==90); StaticPopupDialogs.GOLDTT_RESET_ALL.OnAccept(); assert(next(db.records)==nil and db.roles==roles and db.firstTotal==api.GetTotalGold())")


if __name__ == '__main__':
    unittest.main(verbosity=2)
