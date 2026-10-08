// An `@inline` fragment's value too wide to read in place: 240 linked
// fields, each a nested value read through a `let`, which Kotlin inlines. A
// value's constructor once read every field in place and passed the 64 KiB
// the JVM allows a method at some two hundred such fields; it reads each
// through a function of its own now, and the goldens module compiles this
// host's golden to prove it.
@file:Suppress("unused")

package baton.goldens.wide

import baton.Fragment
import baton.Query

@Fragment($$"""
    fragment WideValue_character on Character @inline @throwOnFieldError {
      link001: origin { id } link002: origin { id } link003: origin { id } link004: origin { id }
      link005: origin { id } link006: origin { id } link007: origin { id } link008: origin { id }
      link009: origin { id } link010: origin { id } link011: origin { id } link012: origin { id }
      link013: origin { id } link014: origin { id } link015: origin { id } link016: origin { id }
      link017: origin { id } link018: origin { id } link019: origin { id } link020: origin { id }
      link021: origin { id } link022: origin { id } link023: origin { id } link024: origin { id }
      link025: origin { id } link026: origin { id } link027: origin { id } link028: origin { id }
      link029: origin { id } link030: origin { id } link031: origin { id } link032: origin { id }
      link033: origin { id } link034: origin { id } link035: origin { id } link036: origin { id }
      link037: origin { id } link038: origin { id } link039: origin { id } link040: origin { id }
      link041: origin { id } link042: origin { id } link043: origin { id } link044: origin { id }
      link045: origin { id } link046: origin { id } link047: origin { id } link048: origin { id }
      link049: origin { id } link050: origin { id } link051: origin { id } link052: origin { id }
      link053: origin { id } link054: origin { id } link055: origin { id } link056: origin { id }
      link057: origin { id } link058: origin { id } link059: origin { id } link060: origin { id }
      link061: origin { id } link062: origin { id } link063: origin { id } link064: origin { id }
      link065: origin { id } link066: origin { id } link067: origin { id } link068: origin { id }
      link069: origin { id } link070: origin { id } link071: origin { id } link072: origin { id }
      link073: origin { id } link074: origin { id } link075: origin { id } link076: origin { id }
      link077: origin { id } link078: origin { id } link079: origin { id } link080: origin { id }
      link081: origin { id } link082: origin { id } link083: origin { id } link084: origin { id }
      link085: origin { id } link086: origin { id } link087: origin { id } link088: origin { id }
      link089: origin { id } link090: origin { id } link091: origin { id } link092: origin { id }
      link093: origin { id } link094: origin { id } link095: origin { id } link096: origin { id }
      link097: origin { id } link098: origin { id } link099: origin { id } link100: origin { id }
      link101: origin { id } link102: origin { id } link103: origin { id } link104: origin { id }
      link105: origin { id } link106: origin { id } link107: origin { id } link108: origin { id }
      link109: origin { id } link110: origin { id } link111: origin { id } link112: origin { id }
      link113: origin { id } link114: origin { id } link115: origin { id } link116: origin { id }
      link117: origin { id } link118: origin { id } link119: origin { id } link120: origin { id }
      link121: origin { id } link122: origin { id } link123: origin { id } link124: origin { id }
      link125: origin { id } link126: origin { id } link127: origin { id } link128: origin { id }
      link129: origin { id } link130: origin { id } link131: origin { id } link132: origin { id }
      link133: origin { id } link134: origin { id } link135: origin { id } link136: origin { id }
      link137: origin { id } link138: origin { id } link139: origin { id } link140: origin { id }
      link141: origin { id } link142: origin { id } link143: origin { id } link144: origin { id }
      link145: origin { id } link146: origin { id } link147: origin { id } link148: origin { id }
      link149: origin { id } link150: origin { id } link151: origin { id } link152: origin { id }
      link153: origin { id } link154: origin { id } link155: origin { id } link156: origin { id }
      link157: origin { id } link158: origin { id } link159: origin { id } link160: origin { id }
      link161: origin { id } link162: origin { id } link163: origin { id } link164: origin { id }
      link165: origin { id } link166: origin { id } link167: origin { id } link168: origin { id }
      link169: origin { id } link170: origin { id } link171: origin { id } link172: origin { id }
      link173: origin { id } link174: origin { id } link175: origin { id } link176: origin { id }
      link177: origin { id } link178: origin { id } link179: origin { id } link180: origin { id }
      link181: origin { id } link182: origin { id } link183: origin { id } link184: origin { id }
      link185: origin { id } link186: origin { id } link187: origin { id } link188: origin { id }
      link189: origin { id } link190: origin { id } link191: origin { id } link192: origin { id }
      link193: origin { id } link194: origin { id } link195: origin { id } link196: origin { id }
      link197: origin { id } link198: origin { id } link199: origin { id } link200: origin { id }
      link201: origin { id } link202: origin { id } link203: origin { id } link204: origin { id }
      link205: origin { id } link206: origin { id } link207: origin { id } link208: origin { id }
      link209: origin { id } link210: origin { id } link211: origin { id } link212: origin { id }
      link213: origin { id } link214: origin { id } link215: origin { id } link216: origin { id }
      link217: origin { id } link218: origin { id } link219: origin { id } link220: origin { id }
      link221: origin { id } link222: origin { id } link223: origin { id } link224: origin { id }
      link225: origin { id } link226: origin { id } link227: origin { id } link228: origin { id }
      link229: origin { id } link230: origin { id } link231: origin { id } link232: origin { id }
      link233: origin { id } link234: origin { id } link235: origin { id } link236: origin { id }
      link237: origin { id } link238: origin { id } link239: origin { id } link240: origin { id }
    }
    """)
fun WideValue() {}

@Query($$"""
    query WideValueQuery {
      character(id: 1) {
        ...WideValue_character
        ... @alias(as: "caughtValue") @catch { ...WideValue_character }
      }
    }
    """)
fun WideValueQuery() {}
