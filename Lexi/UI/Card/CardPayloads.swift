import Foundation

// ---------------------------------------------------------------------------
// Result card payload/model types: pure Decodable structs for the JS bridge
// (Show/Result/Event/Actions/Notes/Review) plus the CardRun stream model.
// ---------------------------------------------------------------------------

struct ShowPayload: Decodable {
    let text: String
    let x: Int
    let y: Int
    let downY: Int?
    let actions: [ToolbarAction]?

    init(text: String, x: Int, y: Int, downY: Int? = nil,
         actions: [ToolbarAction]? = nil) {
        self.text = text
        self.x = x
        self.y = y
        self.downY = downY
        self.actions = actions
    }
}

struct ResultShowPayload: Decodable {
    let runId: String?
    let featureId: String?
    var title: String?
    var icon: String?
    let inputText: String?

    init(runId: String? = nil, featureId: String? = nil, title: String? = nil,
         icon: String? = nil, inputText: String? = nil) {
        self.runId = runId
        self.featureId = featureId
        self.title = title
        self.icon = icon
        self.inputText = inputText
    }
}

struct ResultEventPayload: Decodable {
    let runId: String?
    let chunk: String?
    let done: Bool
    let error: String?
    let translationJson: String?
    let saved: Bool?

    init(runId: String? = nil, chunk: String? = nil, done: Bool = false,
         error: String? = nil, translationJson: String? = nil, saved: Bool? = nil) {
        self.runId = runId
        self.chunk = chunk
        self.done = done
        self.error = error
        self.translationJson = translationJson
        self.saved = saved
    }
}

struct CardActionsPayload: Decodable {
    struct Item: Decodable {
        let id: String
        let name: String
        let icon: String

        init(id: String, name: String, icon: String) {
            self.id = id
            self.name = name
            self.icon = icon
        }
    }
    struct PanelDef: Decodable {
        let id: String
        let name: String
        let icon: String

        init(id: String, name: String, icon: String) {
            self.id = id
            self.name = name
            self.icon = icon
        }
    }
    let actions: [Item]
    let panels: [PanelDef]?

    init(actions: [Item], panels: [PanelDef]? = nil) {
        self.actions = actions
        self.panels = panels
    }
}


struct CardNotesPayload: Decodable {
    var categories: [String]?
    struct Note: Decodable {
        let id: Int64?
        let name: String
        let category: String?
        let content: String
        /// Manual order inside the category (drag-reorder); the clipboard
        /// panel's tabs sort by it.
        var sort: Int = 0

        init(id: Int64? = nil, name: String, category: String? = nil, content: String, sort: Int = 0) {
            self.id = id
            self.name = name
            self.category = category
            self.content = content
            self.sort = sort
        }
    }
    let notes: [Note]

    init(notes: [Note], categories: [String]? = nil) {
        self.notes = notes
        self.categories = categories
    }
}

struct CardReviewPayload: Decodable {
    struct ReviewWord: Decodable {
        let id: Int64
        let word: String
        let translation: String?
        let pos: String?
        let entryType: String?
    }
    let word: ReviewWord?
}

final class CardRun {
    let id: String
    let title: String
    let icon: String
    /// Run lifecycle; the dot colors and pane visibility switch on it.
    enum Status: String { case loading, streaming, ready, error }
    var status: Status = .loading
    var text: String = ""
    var translationJson: String?
    var entryType: String = "word"
    var saved = false
    init(id: String, title: String, icon: String) {
        self.id = id
        self.title = title
        self.icon = icon
    }
}

