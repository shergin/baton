package baton.sample.apollo

import android.app.Application
import android.os.Bundle
import androidx.activity.ComponentActivity
import androidx.activity.compose.BackHandler
import androidx.activity.compose.setContent
import androidx.activity.enableEdgeToEdge
import androidx.activity.viewModels
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.WindowInsets
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.safeDrawing
import androidx.compose.foundation.layout.windowInsetsPadding
import androidx.compose.material3.HorizontalDivider
import androidx.compose.material3.Surface
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.runtime.CompositionLocalProvider
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.runtime.setValue
import androidx.compose.ui.Modifier
import androidx.lifecycle.AndroidViewModel
import androidx.tracing.trace
import baton.macro.FixedServer
import baton.macro.Sections
import baton.sample.apollo.graphql.cache.Cache.cache
import com.apollographql.apollo.ApolloClient
import com.apollographql.cache.normalized.memory.MemoryCacheFactory
import com.apollographql.cache.normalized.sql.SqlNormalizedCacheFactory

/**
 * The Apollo Kotlin twin of `samples/android`: the public Rick and Morty
 * API through Apollo Kotlin and its normalized cache, the characters a page
 * at a time, and a character's detail when one is selected; back returns to
 * the list. The client lives in a view model, so it outlives a rotation,
 * and its cache is the memory cache chained in front of the SQL cache in the
 * app's databases, so the next launch shows what this one fetched before
 * the network answers.
 *
 * A launch whose intent carries `FixedServer.EXTRA` fetches from the fixed
 * server of `benchmarks/macro` instead, and the screens' first draws end
 * the trace sections the macrobenchmark reads; the first list drawn reports
 * the activity fully drawn.
 */
class MainActivity : ComponentActivity() {
    private val model: SampleModel by viewModels()
    private var reportedDrawn = false

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        if (intent.getBooleanExtra(FixedServer.EXTRA, false)) {
            val server = FixedServer.start(this, FixedServer.Client.APOLLO)
            Measurement.avatarAddress = server::avatar
        }
        Measurement.listDrawn = {
            Sections.listDrawn()
            if (!reportedDrawn) {
                reportedDrawn = true
                reportFullyDrawn()
            }
        }
        Measurement.detailDrawn = { Sections.end(Sections.DETAIL_TAP_TO_FRAME) }
        enableEdgeToEdge()
        setContent {
            SampleTheme {
                Surface(modifier = Modifier.fillMaxSize()) {
                    CompositionLocalProvider(LocalApollo provides model.client) {
                        Characters(modifier = Modifier.windowInsetsPadding(WindowInsets.safeDrawing))
                    }
                }
            }
        }
    }
}

/**
 * The client, with the normalized cache as Apollo's documentation chains
 * it for an app that keeps its data across launches: a memory cache in
 * front of the SQL cache, entities keyed by `@typePolicy` and
 * `character(id:)` resolved by `@fieldPolicy`, through the `cache`
 * extension the cache's compiler plugin generates.
 */
class SampleModel(application: Application) : AndroidViewModel(application) {
    val client: ApolloClient = trace(Sections.CLIENT_SETUP) {
        ApolloClient.Builder()
            .serverUrl(FixedServer.graphql("https://rickandmortyapi.com/graphql"))
            .cache(MemoryCacheFactory(maxSizeBytes = 10 * 1024 * 1024).chain(SqlNormalizedCacheFactory(application, "rickandmorty.db")))
            .build()
    }

    override fun onCleared() {
        client.close()
    }
}

/** The list, or the detail of the character selected in it, one at a time. */
@Composable
private fun Characters(modifier: Modifier = Modifier) {
    var page by rememberSaveable { mutableStateOf(1) }
    var selected by rememberSaveable { mutableStateOf<String?>(null) }
    val id = selected
    if (id == null) {
        CharactersScreen(
            page = page,
            onPage = {
                if (it > page) Sections.begin(Sections.PAGE_TURN_TO_FRAME)
                page = it
            },
            onSelect = {
                Sections.begin(Sections.DETAIL_TAP_TO_FRAME)
                selected = it
            },
            modifier = modifier.fillMaxSize(),
        )
        return
    }
    BackHandler { selected = null }
    Column(modifier.fillMaxSize()) {
        TextButton(onClick = { selected = null }) { Text("Characters") }
        HorizontalDivider()
        CharacterScreen(id = id)
    }
}
