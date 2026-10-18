import Testing
@testable import LookoutCore

struct MarkdownBlockTests {
    @Test func planBlocks() {
        let plan = """
        # Plan: create hello.txt

        ## Context
        Create a file `hello.txt`
        in the working directory.

        ## Steps
        1. Write it → verify: exists.
        2) Read it back
          - nested **bold**
        - [ ] todo
        - [x] done
        ---
        ```swift
        let x = 1

        print(x)
        ```
        ##no space
        """
        #expect(MarkdownBlock.parse(plan) == [
            .heading(level: 1, text: "Plan: create hello.txt"),
            .heading(level: 2, text: "Context"),
            .paragraph("Create a file `hello.txt` in the working directory."),
            .heading(level: 2, text: "Steps"),
            .item(marker: "1.", indent: 0, text: "Write it → verify: exists."),
            .item(marker: "2.", indent: 0, text: "Read it back"),
            .item(marker: "•", indent: 1, text: "nested **bold**"),
            .item(marker: "☐", indent: 0, text: "todo"),
            .item(marker: "☑", indent: 0, text: "done"),
            .rule,
            .code("let x = 1\n\nprint(x)"),
            .paragraph("##no space"),
        ])
    }

    @Test func unclosedFenceKeepsItsCode() {
        #expect(MarkdownBlock.parse("text\n```\ncode") == [.paragraph("text"), .code("code")])
    }

    @Test func tables() {
        let blocks = MarkdownBlock.parse("""
        Intro
        | Block | Expected |
        |---|:--|
        | Heading | Larger, `bold` |
        After
        """)
        #expect(blocks == [
            .paragraph("Intro"),
            .table([["Block", "Expected"], ["Heading", "Larger, `bold`"]]),
            .paragraph("After"),
        ])
    }
}
