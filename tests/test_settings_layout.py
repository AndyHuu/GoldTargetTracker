"""Settings readability, responsive layout, and asset relocation regressions."""
import unittest
import test_addon


class SettingsLayoutTests(unittest.TestCase):
    setUp = test_addon.AddonTests.setUp
    boot = test_addon.AddonTests.boot
    run_lua = test_addon.AddonTests.run_lua

    def test_overview_name_and_role_assets_only_in_income(self):
        self.boot()
        self.run_lua("""
            local labels={}
            for _,f in ipairs(frames) do
                if f.kind=='Button' and f.label then labels[#labels+1]=f.label:GetText() end
                if f.text=='角色资产' then
                    assert(f.parent.parent==GoldTargetTrackerIncomePage.content, 'assets not under income')
                end
            end
            assert(table.concat(labels,',')=='总览,金币来源,自动使用,设置')
        """)

    def test_settings_fonts_remain_readable_at_narrow_width(self):
        self.boot()
        self.run_lua("""
            local function inSettings(f)
                while f do if f==GoldTargetTrackerSettingsPanel then return true end; f=f.parent end
            end
            for _,page in ipairs({GoldTargetTrackerOverviewPage,GoldTargetTrackerIncomePage,GoldTargetTrackerOptionsPage}) do
                assert(page and page.kind=='ScrollFrame' and page.scrollChild==page.content)
                for _,width in ipairs({604,400,320}) do
                    page:SetSize(width,450)
                    assert(page.content:GetWidth()<=width and page:GetScale()==1)
                end
            end
            for _,f in ipairs(frames) do
                if f.kind=='FontString' and inSettings(f) and f.font then
                    local parent=f
                    while parent do assert(parent:GetScale()==1,'settings font scaled down'); parent=parent.parent end
                    assert(f.font[2]>=14,'small settings text: '..f:GetText())
                end
            end
        """)

    def test_income_scroll_reaches_assets_and_grows_for_all_roles(self):
        self.boot()
        self.run_lua("""
            local page=GoldTargetTrackerIncomePage
            assert(page and page.content)
            page:SetSize(400,450)
            for i=1,8 do db.roles.Realm['Alt'..i]={gold=i} end
            api.OnEvent(frames[1],'PLAYER_MONEY')
            local collapsed=page.content:GetHeight()
            clickText('展开全部')
            assert(page.content:GetHeight()>collapsed)
            page:SetVerticalScroll(page.content:GetHeight()-page:GetHeight())
            clickText('收起列表')
            assert(page.content:GetHeight()==collapsed)
            assert(page:GetVerticalScroll()<=collapsed-page:GetHeight())
        """)

    def test_graph_reflows_without_scaling_text(self):
        self.boot()
        self.run_lua("""
            local graph
            for _,f in ipairs(frames) do if f.pointData then graph=f.parent; break end end
            assert(graph and graph.scripts.OnSizeChanged)
            graph:SetSize(280,134)
            for _,f in ipairs(frames) do
                if f.pointData then
                    assert(f.point[4]>=0 and f.point[4]<=280,'chart point overflow')
                    assert(f.point[5]>=0 and f.point[5]<=134,'chart point overflow')
                end
            end
        """)

    def test_sections_stretch_and_long_forecasts_wrap_inside_cards(self):
        self.boot()
        self.run_lua("""
            local assets,notes,forecast=0,0,0
            for _,f in ipairs(frames) do
                if f.kind=='FontString' and f.text=='角色资产' then
                    assets=f.parent.points.TOPLEFT[5]
                    assert(f.parent.points.TOPRIGHT, 'asset card has fixed width')
                    assert(f.parent.parent==GoldTargetTrackerIncomePage.content)
                end
                if f.kind=='FontString' and f.text=='统计说明' then notes=f.parent.points.TOPLEFT[5] end
                if f.kind=='FontString' and f.wordWrap==true and f.height==40 and f.parent.parent==GoldTargetTrackerOverviewPage.content then
                    assert(f.points.TOPLEFT and f.points.TOPRIGHT)
                    forecast=forecast+1
                end
            end
            assert(assets<notes and forecast==2, 'asset position or forecast bounds wrong')
        """)


if __name__ == '__main__':
    unittest.main()
