package baton.inspector

import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.material3.HorizontalDivider
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Modifier
import androidx.compose.ui.text.font.FontFamily
import androidx.compose.ui.unit.dp
import baton.Environment
import baton.Record
import baton.Store
import baton.fieldTexts

/**
 * A view over an environment's store, for a debug pane: the store's counts,
 * its records by type, searchable by key or type, each opening onto its
 * fields, values and field errors. It is live: it reads the store's
 * revision as snapshot state, which every batch, collection and end moves,
 * so each recomposes it. It reads and never writes, on the store's thread,
 * where compositions run.
 */
@Composable
fun StoreInspector(environment: Environment, modifier: Modifier = Modifier) {
    val store = environment.store
    var search by remember { mutableStateOf("") }
    var opened by remember { mutableStateOf<String?>(null) }
    // Read first, so any change to the store recomposes the counts and the groups.
    val revision = store.revision
    val groups = remember(store, revision, search) { groups(store, search) }
    Column(modifier) {
        Text(
            "Records ${store.count} · Roots ${store.rootCount} · Optimistic layers ${store.optimisticLayerCount} · Collections ${store.collections}",
            modifier = Modifier.padding(horizontal = 12.dp, vertical = 8.dp),
            style = MaterialTheme.typography.labelMedium,
            color = MaterialTheme.colorScheme.onSurfaceVariant,
        )
        OutlinedTextField(
            value = search,
            onValueChange = { search = it },
            placeholder = { Text("Key or type") },
            singleLine = true,
            modifier = Modifier.fillMaxWidth().padding(horizontal = 12.dp),
        )
        LazyColumn(modifier = Modifier.fillMaxWidth().padding(top = 8.dp)) {
            for (group in groups) {
                item(key = "type:" + group.type) {
                    Text(
                        "${group.type} (${group.records.size})",
                        modifier = Modifier.fillMaxWidth().padding(horizontal = 12.dp, vertical = 6.dp),
                        style = MaterialTheme.typography.titleSmall,
                        color = MaterialTheme.colorScheme.primary,
                    )
                }
                items(group.records, key = { "record:" + it.key }) { record ->
                    RecordRow(
                        store = store,
                        record = record,
                        opened = opened == record.key,
                        onClick = { opened = if (opened == record.key) null else record.key },
                    )
                }
            }
        }
    }
}

/** The records of one type, sorted by key. */
private class Group(val type: String, val records: List<Record>)

/** The records by type name, each group's records by key, those whose key or type the search matches. */
private fun groups(store: Store, search: String): List<Group> {
    val byType = HashMap<String, MutableList<Record>>()
    for (record in store.recordsByKey().values) {
        val type = record.type.name
        if (search.isNotEmpty() && !record.key.contains(search, ignoreCase = true) && !type.contains(search, ignoreCase = true)) continue
        byType.getOrPut(type) { ArrayList() }.add(record)
    }
    return byType.keys.sorted().map { type -> Group(type, byType.getValue(type).sortedBy { it.key }) }
}

/** One record's key; opened, its fields by storage key with their values and errors. */
@Composable
private fun RecordRow(store: Store, record: Record, opened: Boolean, onClick: () -> Unit) {
    Column(modifier = Modifier.fillMaxWidth().clickable(onClick = onClick).padding(horizontal = 12.dp, vertical = 6.dp)) {
        Text(record.key, style = MaterialTheme.typography.bodyMedium, fontFamily = FontFamily.Monospace)
        if (opened) Fields(store, record)
    }
    HorizontalDivider()
}

/**
 * A record's fields, read under the store's revision: every commit
 * recomposes this, which brings a changed value and a field the record did
 * not hold before.
 */
@Composable
private fun Fields(store: Store, record: Record) {
    store.revision
    Column(modifier = Modifier.padding(start = 12.dp, top = 4.dp), verticalArrangement = Arrangement.spacedBy(4.dp)) {
        if (record.deleted) Text("Deleted", color = MaterialTheme.colorScheme.error, style = MaterialTheme.typography.labelMedium)
        for ((key, value, error) in store.fieldTexts(record).sortedBy { it.first }) {
            Column {
                Text(key, style = MaterialTheme.typography.labelMedium, color = MaterialTheme.colorScheme.onSurfaceVariant)
                Text(value, style = MaterialTheme.typography.bodySmall, fontFamily = FontFamily.Monospace)
                if (error != null) {
                    Text("${error.message} at ${error.path}", style = MaterialTheme.typography.bodySmall, color = MaterialTheme.colorScheme.error)
                }
            }
        }
    }
}
