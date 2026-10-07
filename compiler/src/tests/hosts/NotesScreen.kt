// A Kotlin host with the four markers, one in each form of string literal.
// The "quotes" in this comment and the @Query( here are not scanned.
@file:Suppress("unused")

package com.example.notes

import baton.Fragment
import baton.Mutation
import baton.Query

/* A block comment /* nested */ with @Fragment("fragment Not on Note { id }"). */
private const val TITLE = "not a @Query(\"document\") either: ${'$'}{1 + 1}"

@Fragment("fragment NoteRow_note on Note {\n  id\n  text\n}")
fun NoteRow(note: NoteRow_note) {}

@Query(
    """
    query NotesScreenQuery {
      character(id: "1") {
        id
        name
      }
    }
    """
)
fun NotesScreen() {}

@Mutation(document = $$"""
    mutation AddNoteMutation($characterId: ID!, $text: String!) {
      addNote(characterId: $characterId, text: $text) {
        note {
          ...NoteRow_note
        }
      }
    }
    """)
fun AddNoteButton() {}

@baton.Subscription($$"subscription NoteAddedSubscription($characterId: ID!) { noteAdded(characterId: $characterId) { character { id } } }")
fun NoteFeed() {}
