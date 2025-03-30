#!/bin/bash
# Configuration
GROQ_API_KEY="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"
MODEL="deepseek-r1-distill-qwen-32b"
STORAGE_DIR="./diary_storage"
DATA_FILE="$STORAGE_DIR/memories.json"
LOG_FILE="$STORAGE_DIR/conversation_log.jsonl"
PROMPT_FILE="$STORAGE_DIR/extraction_prompt.txt"
ANALYSIS_DIR="$STORAGE_DIR/analysis"
DATE=$(date +"%Y-%m-%d")
TIMESTAMP=$(date +"%Y-%m-%d_%H-%M-%S")
ENTRY_ID="${TIMESTAMP}_$(openssl rand -hex 4)"

# Ensure required tools are available
for cmd in curl jq openssl; do
    if ! command -v $cmd &>/dev/null; then
        echo "Error: $cmd is required but not installed. Please install it and try again."
        exit 1
    fi
done

# Initialize storage directory and files
initialize_storage() {
    # Create storage directory if it doesn't exist
    mkdir -p "$STORAGE_DIR"
    mkdir -p "$ANALYSIS_DIR"
    
    # Initialize data file if it doesn't exist
    if [ ! -f "$DATA_FILE" ]; then
        echo '{
            "entries": {},
            "entities": {
                "people": {},
                "places": {},
                "events": {},
                "objects": {}
            },
            "indexes": {
                "dates": {},
                "topics": {},
                "emotions": {}
            }
        }' | jq '.' > "$DATA_FILE"
        echo "Created new data file: $DATA_FILE"
    fi
    
    # Check if prompt file exists, but don't overwrite it if it already exists
    if [ ! -f "$PROMPT_FILE" ]; then
        cat > "$PROMPT_FILE" << 'EOF'
Extract structured information from this diary entry. Focus on key memories, experiences, people, places, emotions, and events.
Format your response STRICTLY as a valid JSON with the following structure:
{
  "summary": "Brief 1-2 sentence summary of the entry",
  "date": "YYYY-MM-DD",
  "time_of_day": "morning/afternoon/evening/night",
  "location": "Location where events took place",
  "topics": ["topic1", "topic2"],
  "emotions": ["emotion1", "emotion2"],
  "entities": {
    "people": [{"name": "Person name", "relationship": "Relationship to user", "context": "Brief context of interaction"}],
    "places": [{"name": "Place name", "significance": "Why this place matters"}],
    "events": [{"name": "Event description", "significance": "Why this event matters"}],
    "objects": [{"name": "Object name", "significance": "Why this object matters"}]
  },
  "facts": ["Important fact 1", "Important fact 2"],
  "reflections": ["Personal reflection/thought 1", "Personal reflection/thought 2"]
}
IMPORTANT: Output ONLY the JSON with no additional text, explanation, or formatting. Do not use markdown code blocks. Only return the raw JSON object.
EOF
        echo "Created extraction prompt template: $PROMPT_FILE"
        echo "You can edit this file to customize the extraction process."
    else
        echo "Using existing prompt file: $PROMPT_FILE"
    fi
}

# Escape strings for JSON
escape_json() {
    echo "$1" | jq -Rs '.'
}

# Call Groq API for extraction
extract_structured_data() {
    local entry_text="$1"
    local prompt
    
    # Read the external prompt file
    if [ -f "$PROMPT_FILE" ]; then
        prompt=$(cat "$PROMPT_FILE")
    else
        echo "Error: Prompt file not found. Creating default prompt file." >&2
        initialize_storage
        prompt=$(cat "$PROMPT_FILE")
    fi
    
    local max_retries=3
    local retry_count=0
    local response=""
    
    # Create JSON payload - modified to ensure raw JSON output
    local payload=$(jq -n \
        --arg model "$MODEL" \
        --arg system "$prompt" \
        --arg user "$entry_text" \
        '{
            "model": $model,
            "temperature": 0.3,
            "response_format": {"type": "json_object"},
            "messages": [
                {"role": "system", "content": $system},
                {"role": "user", "content": $user}
            ]
        }')
        
    # Try API call with retries
    while [ $retry_count -lt $max_retries ]; do
        response=$(curl -s -X POST "https://api.groq.com/openai/v1/chat/completions" \
            -H "Authorization: Bearer $GROQ_API_KEY" \
            -H "Content-Type: application/json" \
            -d "$payload")
        
        # Check if we got a valid response
        if echo "$response" | jq -e '.choices[0].message.content' &>/dev/null; then
            # Extract just the content field containing our JSON
            local raw_extraction=$(echo "$response" | jq -r '.choices[0].message.content')
            
            # Ensure it's clean JSON with no extra formatting
            local clean_extraction
            
            # Try to parse the extraction as JSON directly
            if clean_extraction=$(echo "$raw_extraction" | jq '.' 2>/dev/null); then
                # If successful, save the validated JSON
                echo "$clean_extraction" > "$ANALYSIS_DIR/${ENTRY_ID}_analysis.json"
                echo "Analysis saved to: $ANALYSIS_DIR/${ENTRY_ID}_analysis.json"
                echo "$clean_extraction"
                return 0
            else
                echo "API returned invalid JSON format. Attempting to clean..." >&2
                
                # Try to clean up the extraction by removing markdown code blocks if present
                # and any other non-JSON text
                clean_extraction=$(echo "$raw_extraction" | sed -E 's/^```(json)?//g' | sed -E 's/```$//g' | tr -d '\r')
                
                # Validate the cleaned JSON
                if echo "$clean_extraction" | jq '.' &>/dev/null; then
                    echo "$clean_extraction" > "$ANALYSIS_DIR/${ENTRY_ID}_analysis.json"
                    echo "Analysis saved after cleanup: $ANALYSIS_DIR/${ENTRY_ID}_analysis.json"
                    echo "$clean_extraction"
                    return 0
                else
                    echo "Failed to clean JSON response:" >&2
                    echo "$raw_extraction" >&2
                fi
            fi
        else
            echo "API call failed or returned invalid format." >&2
            echo "Response: $response" >&2
        fi
        
        retry_count=$((retry_count + 1))
        echo "Extraction failed (attempt $retry_count/$max_retries). Retrying..." >&2
        sleep 2
    done
    
    # Return empty structure if failed
    echo '{
        "summary": "Failed to extract structured data",
        "date": "'$DATE'",
        "topics": [],
        "emotions": [],
        "entities": {
            "people": [],
            "places": [],
            "events": [],
            "objects": []
        },
        "facts": [],
        "reflections": []
    }'
    return 1
}

# Update storage with new data - improved JSON handling
update_storage() {
    local entry_text="$1"
    local extraction="$2"
    
    # Create backup of current data
    cp "$DATA_FILE" "${DATA_FILE}.bak"
    
    # Log the raw conversation 
    echo "{\"id\":\"$ENTRY_ID\",\"timestamp\":\"$TIMESTAMP\",\"text\":$(escape_json "$entry_text")}" >> "$LOG_FILE"
    
    # First, validate the extraction is proper JSON before passing to jq
    if ! echo "$extraction" | jq empty &>/dev/null; then
        echo "Error: Invalid extraction JSON. Cannot update storage." >&2
        cat "${DATA_FILE}.bak" > "$DATA_FILE"  # Restore backup
        return 1
    fi
    
    # Save extraction to temporary file to avoid command line size limitations and escaping issues
    echo "$extraction" > "${STORAGE_DIR}/${ENTRY_ID}_temp.json"
    
    # Update data file using temporary file instead of passing JSON directly
    jq --slurpfile extraction "${STORAGE_DIR}/${ENTRY_ID}_temp.json" \
       --arg entry_id "$ENTRY_ID" \
       --arg timestamp "$TIMESTAMP" \
       --arg date "$DATE" \
    '
    # Helper function to merge objects without overwriting
    def deep_merge(a; b):
        a as $a | b as $b |
        if ($a|type) == "object" and ($b|type) == "object" then
            reduce ([$a,$b] | add | keys_unsorted[]) as $k ({}; 
                if $a[$k] and $b[$k] and ($a[$k]|type) == "object" and ($b[$k]|type) == "object" then
                    .[$k] = deep_merge($a[$k]; $b[$k])
                elif $a[$k] and $b[$k] and ($a[$k]|type) == "array" and ($b[$k]|type) == "array" then
                    .[$k] = ($a[$k] + $b[$k] | unique)
                elif $b[$k] then
                    .[$k] = $b[$k]
                else
                    .[$k] = $a[$k]
                end
            )
        elif ($a|type) == "array" and ($b|type) == "array" then
            $a + $b | unique
        else
            $b // $a
        end;
    
    # Store the entry with its ID and full extraction data (using first item from slurpfile array)
    .entries[$entry_id] = $extraction[0] |
    
    # Update date index
    .indexes.dates[$date] = (.indexes.dates[$date] // []) + [$entry_id] |
    
    # Update topic indexes
    reduce ($extraction[0].topics[]? // empty) as $topic (.; 
        .indexes.topics[$topic] = (.indexes.topics[$topic] // []) + [$entry_id]
    ) |
    
    # Update emotion indexes
    reduce ($extraction[0].emotions[]? // empty) as $emotion (.; 
        .indexes.emotions[$emotion] = (.indexes.emotions[$emotion] // []) + [$entry_id]
    ) |
    
    # Process people entities with complex data support
    reduce ($extraction[0].entities.people[]? // empty) as $person (.;
        .entities.people[$person.name] = deep_merge(
            .entities.people[$person.name] // {}; 
            {
                "relationship": $person.relationship,
                "last_seen": $date,
                "context": $person.context,
                "metadata": {
                    "first_mentioned": (.entities.people[$person.name].metadata.first_mentioned // $date),
                    "mention_count": ((.entities.people[$person.name].metadata.mention_count // 0) + 1)
                },
                "entries": ((.entities.people[$person.name].entries // []) + [$entry_id] | unique),
                "interactions": (.entities.people[$person.name].interactions // {}) + {
                    ($entry_id): {
                        "date": $date,
                        "context": $person.context
                    }
                }
            }
        )
    ) |
    
    # Process place entities with complex data support
    reduce ($extraction[0].entities.places[]? // empty) as $place (.;
        .entities.places[$place.name] = deep_merge(
            .entities.places[$place.name] // {}; 
            {
                "significance": $place.significance,
                "last_visited": $date,
                "metadata": {
                    "first_mentioned": (.entities.places[$place.name].metadata.first_mentioned // $date),
                    "visit_count": ((.entities.places[$place.name].metadata.visit_count // 0) + 1)
                },
                "entries": ((.entities.places[$place.name].entries // []) + [$entry_id] | unique),
                "visits": (.entities.places[$place.name].visits // {}) + {
                    ($entry_id): {
                        "date": $date,
                        "significance": $place.significance
                    }
                }
            }
        )
    ) |
    
    # Process event entities with complex data support
    reduce ($extraction[0].entities.events[]? // empty) as $event (.;
        .entities.events[$event.name] = deep_merge(
            .entities.events[$event.name] // {}; 
            {
                "significance": $event.significance,
                "date": $date,
                "metadata": {
                    "first_mentioned": (.entities.events[$event.name].metadata.first_mentioned // $date),
                    "mention_count": ((.entities.events[$event.name].metadata.mention_count // 0) + 1)
                },
                "entries": ((.entities.events[$event.name].entries // []) + [$entry_id] | unique),
                "references": (.entities.events[$event.name].references // {}) + {
                    ($entry_id): {
                        "date": $date,
                        "significance": $event.significance
                    }
                }
            }
        )
    ) |
    
    # Process object entities with complex data support
    reduce ($extraction[0].entities.objects[]? // empty) as $object (.;
        .entities.objects[$object.name] = deep_merge(
            .entities.objects[$object.name] // {}; 
            {
                "significance": $object.significance,
                "last_mentioned": $date,
                "metadata": {
                    "first_mentioned": (.entities.objects[$object.name].metadata.first_mentioned // $date),
                    "mention_count": ((.entities.objects[$object.name].metadata.mention_count // 0) + 1)
                },
                "entries": ((.entities.objects[$object.name].entries // []) + [$entry_id] | unique),
                "mentions": (.entities.objects[$object.name].mentions // {}) + {
                    ($entry_id): {
                        "date": $date,
                        "significance": $object.significance
                    }
                }
            }
        )
    )
    ' "${DATA_FILE}.bak" > "$DATA_FILE.tmp"
    
    # Check if operation was successful
    if [ $? -eq 0 ] && [ -s "$DATA_FILE.tmp" ]; then
        # Validate the new data file
        if jq empty "$DATA_FILE.tmp" &>/dev/null; then
            mv "$DATA_FILE.tmp" "$DATA_FILE"
            echo "Diary entry stored successfully with ID: $ENTRY_ID"
            # Clean up temporary files
            rm -f "${DATA_FILE}.bak"
            rm -f "${STORAGE_DIR}/${ENTRY_ID}_temp.json"
        else
            echo "Error: Generated invalid JSON. Restoring backup." >&2
            mv "${DATA_FILE}.bak" "$DATA_FILE"
            rm -f "$DATA_FILE.tmp"
            rm -f "${STORAGE_DIR}/${ENTRY_ID}_temp.json"
        fi
    else
        echo "Error: Failed to update data file. Restoring backup." >&2
        mv "${DATA_FILE}.bak" "$DATA_FILE"
        rm -f "$DATA_FILE.tmp"
        rm -f "${STORAGE_DIR}/${ENTRY_ID}_temp.json"
    fi
}

# Display help
show_help() {
    cat << EOF
Diary Memory Storage System
Usage:
  !help      - Show this help message
  !prompt    - Show current extraction prompt
  !edit      - Edit the extraction prompt (opens in default editor)
  exit       - Exit the system
  
Simply type your diary entry, and the system will automatically
extract and store the important information.
Entry ID: $ENTRY_ID
Date: $DATE
Storage Directory: $STORAGE_DIR
Analysis Files: $ANALYSIS_DIR
EOF
}

# Show prompt
show_prompt() {
    if [ -f "$PROMPT_FILE" ]; then
        echo "Current extraction prompt:"
        echo "--------------------------------"
        cat "$PROMPT_FILE"
        echo "--------------------------------"
    else
        echo "Prompt file not found. Creating default prompt file."
        initialize_storage
        show_prompt
    fi
}

# Edit prompt
edit_prompt() {
    if [ -f "$PROMPT_FILE" ]; then
        if [ -n "$EDITOR" ]; then
            $EDITOR "$PROMPT_FILE"
        elif command -v nano &>/dev/null; then
            nano "$PROMPT_FILE"
        elif command -v vim &>/dev/null; then
            vim "$PROMPT_FILE"
        else
            echo "No editor found. Please manually edit: $PROMPT_FILE"
        fi
    else
        echo "Prompt file not found. Creating default prompt file."
        initialize_storage
        edit_prompt
    fi
}

# Main function
main() {
    # Initialize storage
    initialize_storage
    
    # Welcome message
    echo "Diary Memory Storage System (Enhanced)"
    echo "--------------------------------------"
    echo "Today's date: $DATE"
    echo "Entry ID: $ENTRY_ID"
    echo "Using extraction prompt: $PROMPT_FILE"
    echo "Type your diary entry (type 'exit' to quit, '!help' for commands)"
    echo "To finish your entry, type 'END' on a line by itself"
    echo "--------------------------------------"
    
    # Main chat loop
    while true; do
        # Get user input
        echo -n "Diary entry: "
        # Read multiline input until "END" is typed on a line by itself
        user_input=""
        while IFS= read -r line; do
            if [ "$line" = "END" ]; then
                break
            elif [ "$line" = "exit" ]; then
                echo "Goodbye! Your diary entries have been saved."
                exit 0
            elif [ "$line" = "!help" ]; then
                show_help
                echo "Type your diary entry or continue with 'END' to finish:"
                continue
            elif [ "$line" = "!prompt" ]; then
                show_prompt
                echo "Type your diary entry or continue with 'END' to finish:"
                continue
            elif [ "$line" = "!edit" ]; then
                edit_prompt
                echo "Type your diary entry or continue with 'END' to finish:"
                continue
            fi
            user_input+="$line"$'\n'
        done
        
        # Skip if input is empty
        if [ -z "$(echo "$user_input" | tr -d '[:space:]')" ]; then
            echo "Empty entry. Try again or type 'exit' to quit."
            continue
        fi
        
        # Extract structured data
        echo "Processing entry..."
        extraction=$(extract_structured_data "$user_input")
        
        # Update storage with new information
        update_storage "$user_input" "$extraction"
        
        # Generate new entry ID for next entry
        TIMESTAMP=$(date +"%Y-%m-%d_%H-%M-%S")
        ENTRY_ID="${TIMESTAMP}_$(openssl rand -hex 4)"
        
        echo "Entry processed and stored."
        echo "New Entry ID: $ENTRY_ID"
        echo "--------------------------------------"
    done
}

# Run the main function
main