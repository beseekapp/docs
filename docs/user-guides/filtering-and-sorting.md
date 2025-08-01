# User Guide: Filtering and Sorting Data

This guide explains how to use Beseek's powerful filtering and sorting capabilities to refine your data and focus on what matters most. You can define precise criteria using either a simple text prompt or an intuitive drag-and-drop interface.

## Using the Criteria Prompt

The criteria prompt offers a fast and flexible way to specify how your data should be filtered and sorted. You can type natural language commands to define your rules.

### How It Works

1.  **Navigate to the Data View**: Open the dataset you wish to analyze.
2.  **Locate the Criteria Prompt**: Find the input field labeled "Filter & Sort Criteria" at the top of your data table.
3.  **Write Your Criteria**: Enter your filtering and sorting rules. You can specify conditions for including or excluding data and define the order in which results should appear.

**Examples:**

*   To show only documents created in the last 7 days, you could type: `created_date in the last 7 days`
*   To find all tasks assigned to "John Doe" and sort them by priority, you might write: `assigned_to is "John Doe" sort by priority descending`
*   To filter for invoices over $500 from the "ABC Corp" client, you could use: `client is "ABC Corp" and amount > 500`

The system intelligently parses your input and applies the rules to your dataset in real-time.

## Using the Drag & Drop Criteria Builder

For a more visual approach, the drag-and-drop criteria builder allows you to construct rules without writing any text.

### How It Works

1.  **Open the Criteria Builder**: Click the "Builder" button next to the criteria prompt to launch the drag-and-drop interface.
2.  **Select Fields**: On the left, you'll see a list of available data fields (e.g., "Status," "Creation Date," "Assigned User").
3.  **Build Filter Rules**:
    *   Drag a field into the "Filters" area.
    *   Select an operator (e.g., `is`, `is not`, `contains`, `greater than`).
    *   Provide a value to complete the rule (e.g., `Status is "Completed"`).
    *   Add multiple rules using "AND" / "OR" logic to create complex conditions.
4.  **Define Sorting Order**:
    *   Drag a field into the "Sort By" area.
    *   Choose the sort direction: `Ascending` (A-Z, 0-9) or `Descending` (Z-A, 9-0).
    *   Add multiple sorting levels to define how to handle ties (e.g., sort by `Priority` descending, then by `Creation Date` ascending).
5.  **Apply Criteria**: Once you've built your rules, click "Apply" to see the results. Your criteria will be translated into text and displayed in the prompt, so you can learn the syntax as you go.

By combining these tools, you can efficiently navigate large datasets, isolate key information, and organize your results to match your specific needs.