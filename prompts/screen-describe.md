You are analyzing an iPhone screenshot for UI automation. Your job is to identify every tappable and interactive element on the screen.

Return a JSON array where each element has:
- `label`: The visible text label of the element (exactly as shown on screen)
- `x`: The X coordinate (in pixels) of the center of the tappable area
- `y`: The Y coordinate (in pixels) of the center of the tappable area
- `type`: One of: `app`, `dock_app`, `button`, `tab`, `card`, `link`, `icon`, `back_button`, `search_bar`, `toggle`, `text_field`, `nav_title`, `status_bar_time`, `status_bar_icons`

Rules:
- Coordinates must be relative to the image dimensions (top-left is 0,0)
- Include ALL tappable elements: buttons, tabs, cards, links, icons, toggles, text fields
- For app icons, include the app name as the label
- For badge counts, note them in the label (e.g. "Calendrier" with badge)
- For cards with values (e.g. health data), combine title and value in the label
- For navigation elements (back chevron "<"), use type `back_button`
- For tab bars at the bottom, use type `tab`
- Do NOT include decorative or non-interactive elements
- Return ONLY the JSON array, no explanation or markdown fences
