import Foundation
import FridayCore
import Testing

@testable import FridayComputer

@Suite struct UITreeTests {
    let tree = FakeTrees.saveSheet()

    @Test func describesCompactly() {
        let text = tree.describe()
        let lines = text.split(separator: "\n").map(String.init)
        #expect(lines[0] == "App: TextEdit (pid 42) · Window: \"Untitled\" (0,25 800×600)")
        #expect(lines[1] == "Focused: e4 text field \"Name\"")
        #expect(text.contains("[e2] button \"Save\" (at 740,575)"))
        #expect(text.contains("[e4] text field \"Name\" = \"report.txt\" [focused] (at 300,112)"))
        #expect(text.contains("[e7] button \"Eliminar\" [disabled] (at 140,575)"))
        #expect(text.contains("[e8] scroll area [scrolled 30%] (at 400,360)"))
        #expect(text.contains("Visible text: Choose a name for the document | Name"))
        #expect(text.contains("[e1] window \"Untitled\""))
    }

    @Test func neverRevealsSecureValues() {
        let text = tree.describe()
        #expect(text.contains("[e6] password field \"Password\" [secure]"))
        #expect(!text.contains("hunter"))
        #expect(tree.element("e6")?.value == nil)
        #expect(tree.element("e6")?.json["secure"]?.boolValue == true)
        #expect(tree.element("e6")?.json["value"] == nil)
    }

    @Test func honoursTheLineBudget() {
        let text = tree.describe(maxLines: 5)
        let lines = text.split(separator: "\n")
        #expect(lines.count <= 6)
        #expect(text.contains("more elements (raise max_lines)"))
    }

    @Test func findsByLabelValueRoleAndId() {
        #expect(tree.find("Save").first?.id == "e2")
        #expect(tree.find("save").first?.id == "e2")
        #expect(tree.find("e3").first?.id == "e3")
        #expect(tree.find("cancle").first?.id == "e3")
        #expect(tree.find("the Name field").first?.id == "e4")
        #expect(tree.find("report.txt").first?.id == "e4")
        #expect(tree.find("botón Eliminar").first?.id == "e7")
        #expect(tree.find("ELIMINAR").first?.id == "e7")
        #expect(tree.find("password field").first?.id == "e6")
        #expect(tree.find("nothing like this").isEmpty)
    }

    @Test func ranksExactMatchesFirst() {
        var copy = tree
        let saveAs = UIElementSnapshot(id: "e9", role: "AXButton", label: "Save As…", frame: ScreenRect(x: 500, y: 560, width: 80, height: 30), actions: ["AXPress"], path: [7])
        copy.elements["e9"] = saveAs
        copy.order.append("e9")
        let matches = copy.find("save")
        #expect(matches.map(\.id) == ["e2", "e9"])
        #expect(copy.find("save as").first?.id == "e9")
    }

    @Test func reportsRichnessAndContext() {
        #expect(!tree.isRich)
        #expect(tree.contextText.contains("Untitled"))
        #expect(tree.contextText.contains("Choose a name for the document"))
        #expect(tree.notable.map(\.id) == ["e1", "e2", "e3", "e4", "e5", "e6", "e7", "e8"])
    }

    @Test func roleNamesAreHumanReadable() {
        #expect(UIElementSnapshot.roleName("AXPopUpButton") == "pop-up")
        #expect(UIElementSnapshot.roleName("AXDisclosureTriangle") == "disclosure triangle")
        #expect(UIElementSnapshot.roleName("AXStaticText") == "text")
        #expect(UIElementSnapshot.roleName("AXCheckBox") == "check box")
    }

    @Test func roundTripsThroughCodable() throws {
        let data = try JSONEncoder().encode(tree)
        let decoded = try JSONDecoder().decode(UITree.self, from: data)
        #expect(decoded.order == tree.order)
        #expect(decoded.element("e4")?.value == "report.txt")
        #expect(decoded.scope == .frontmostWindow)
        #expect(decoded.window?.id == 77)
    }

    @Test func jsonListsNotableElements() {
        let json = tree.json
        #expect(json["count"]?.intValue == 8)
        #expect(json["focused"]?.stringValue == "e4")
        #expect(json["elements"]?.arrayValue?.count == 8)
        #expect(json["window"]?["title"]?.stringValue == "Untitled")
    }
}
