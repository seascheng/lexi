1. Please evaluate my proposal based on the current implementation and target requirements before executing it, rather than blindly following.
2. Fixing bugs must involve upward exploration, adopting a general solution from the root cause instead of woraround, cleaning up old code at last.
3. For implementing new feature , it is essential to ensure code reusability and follow the current file directory based on the existing architecture.
4. We pursue the separation of duties while avoiding excessive complexity and abstraction; we aim for clean code while avoiding fragmentation.

<claude-mem-context>
# Memory Context

# [englist-tool] recent context, 2026-05-01 8:52pm GMT+8

Legend: 🎯session 🔴bugfix 🟣feature 🔄refactor ✅change 🔵discovery ⚖️decision 🚨security_alert 🔐security_note
Format: ID TIME TYPE TITLE
Fetch details: get_observations([IDs]) | Search: mem-search skill

Stats: 50 obs (16,123t read) | 0t work

### Apr 30, 2026
S58 Enhanced Review interface with manual navigation and window pinning controls (Apr 30 at 8:48 PM)
S59 Enhanced Review interface with manual navigation and window pinning controls (Apr 30 at 9:02 PM)
S60 Enhanced Review interface with manual navigation and window pinning controls (Apr 30 at 9:02 PM)
S61 User asked for a better learning solution for phrases and sentences, pointing out that current JSON-based approach limits extensibility and burdens smaller LLMs (Apr 30 at 9:02 PM)
### May 1, 2026
248 9:43a 🔵 Explored englist-tool architecture and data model
249 " 🔵 Analyzed current vocabulary learning implementation
251 " 🔵 Explored AI command backend and translation window flow control
252 " ⚖️ Identified need for generic, extensible translation output format
250 9:44a 🔵 Explored AI integration and translation display implementation
S66 Product philosophy clarification establishing popup as primary daily learning workspace with codebase exploration for implementation planning (May 1 at 10:37 AM)
S64 Product philosophy clarification establishing popup as primary daily learning workspace, not auxiliary translation window (May 1 at 10:43 AM)
S62 Approved architectural direction for phrase/sentence learning feature with refinements for minimal viable implementation (May 1 at 10:43 AM)
S63 Refinement of phrase/sentence learning feature with minimal viable product approach and product principle establishment (May 1 at 10:43 AM)
S65 Approved architectural direction with minimal viable product implementation strategy for phrase/sentence learning feature (May 1 at 10:43 AM)
S67 Product philosophy clarification establishing popup as primary daily learning workspace followed by codebase exploration for implementation planning (May 1 at 10:46 AM)
253 10:58a ⚖️ Tool-based extensibility architecture proposed for learning point actions
254 11:02a ⚖️ Tool-based extensibility architecture approved for implementation planning
255 11:03a ⚖️ Implementation plan established for tool-based learning point capture system
256 11:04a 🟣 Database schema extended to support phrase and pattern learning entries
257 11:05a 🟣 Database layer updated to support learning entry metadata
258 " 🟣 Browser storage compatibility layer added for learning entry fields
259 " 🟣 Export and AI analysis capabilities implemented for learning point capture
260 " 🟣 Capture learning point button added to popup frame
261 " 🟣 Learning point capture workflow implemented in TranslationWindow
262 11:06a 🟣 Capture action panel UI integration added to FeatureTabPage
263 " 🟣 CaptureActionPanel UI component implemented with full editing interface
264 " 🟣 Helper functions implemented for learning point capture workflow
265 " ✅ Implementation plan updated with progress tracking
266 11:07a 🟣 Vocabulary and review display adapted for entry type and capture notes
268 " 🟣 Review interface adapted for entry type display and note field
267 " ✅ Main navigation label updated from Vocabulary to Expressions
269 " 🟣 Popup review interface adapted for entry type display
270 11:08a 🟣 Build verification completed successfully for learning point capture feature
271 " ⚖️ Product design principle: minimize interface complexity
272 6:46p 🔄 Simplified capture learning point UI by removing draft editing complexity
273 " 🔄 Streamlined CaptureActionPanel interface by removing draft editing controls
274 " 🔄 Removed draft editing interface from CaptureActionPanel
275 " 🔄 Completed capture learning point UI simplification to minimal interface
276 6:47p 🟣 Successfully built simplified capture learning point interface
277 6:49p 🟣 Added entry type selection to simplified capture interface
278 " 🟣 Built simplified capture interface with entry type selection
279 " 🔵 Capture learning point analyzes input text instead of selected text
280 6:55p 🔴 Fixed text selection priority in capture learning point
281 " 🔴 Enhanced AI prompt to prevent text extraction from selected content
282 " 🟣 Enhanced sentence pattern detection in inferredEntryType
283 6:56p 🔴 Built fixed capture learning point with text selection corrections
284 " 🔵 Edit feature Save button creates duplicate instead of updating
285 7:04p 🔵 Investigated FeaturesPage edit-save functionality to identify duplication bug
286 " 🔴 Fixed normalizedFeatureId to preserve existing custom feature IDs
287 " 🔵 User requested further UI simplification for popup window
288 7:07p 🔄 Implemented automatic popup resizing and removed capture learning point UI
289 7:09p 🔄 Removed FeatureActionBar and set minimum content height for popup
290 8:23p 🟣 Implemented automatic popup window resizing based on content height
291 " 🔵 Popup window auto-height adjustment not working
292 8:35p 🔵 Auto-height feature non-functional after implementation
293 8:41p 🔵 Tauri window resize permissions correctly configured
295 " 🟣 Created Rust backend command for popup height adjustment
294 " 🔵 Potential LogicalSize vs PhysicalSize mismatch in auto-height
296 " 🟣 Registered set_popup_height Tauri command in invoke_handler
297 8:42p 🔴 Fixed auto-height by switching to backend set_popup_height command
</claude-mem-context>
