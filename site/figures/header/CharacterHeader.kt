package app

import androidx.compose.foundation.layout.Column
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import baton.Fragment

@Fragment("""
    fragment CharacterHeader_character on Character {
      name
      status
      species
      image
      origin { name }
    }
    """)
@Composable
fun CharacterHeader(character: CharacterHeader_character) {
    Column {
        Avatar(url = character.image)
        Text(character.name ?: "Unknown", style = MaterialTheme.typography.headlineLarge)
        Text("${character.status ?: "?"} · ${character.species ?: "?"}")
        character.origin?.let { origin ->
            Text("From ${origin.name ?: "somewhere"}")
        }
    }
}
