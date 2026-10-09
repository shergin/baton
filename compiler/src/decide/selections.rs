//! The selections of a plan, each declared once and numbered from the root.
//! Which selection is declared where and under which number is one fact of
//! the plan, decided here for both printers, whatever the language spells
//! it in (`docs/decisions/a-plan-declares-each-selection-once.md`).

use std::collections::HashMap;

use super::{NormalizationKind, NormalizationSelection};

/// The distinct selections of a plan, numbered from the root: the root is
/// 0, and each selection follows the first that refers to it, so a plan
/// reads from the top down. Two selections are one when the normalization
/// decided them alike: the same type, key, fields, slots, guards, labels and
/// the selections below them; a fragment spread in two places shares its
/// declaration only where every fact of it is equal.
pub struct SelectionTable<'a> {
    /// The declared selections, by number.
    declared: Vec<&'a NormalizationSelection>,
    /// The number of every selection of the plan, by its address: a
    /// selection equal to one declared before it has that one's number.
    numbers: HashMap<*const NormalizationSelection, usize>,
}

impl<'a> SelectionTable<'a> {
    /// The table of the plan rooted at `root`.
    pub fn of(root: &'a NormalizationSelection) -> SelectionTable<'a> {
        let mut table = SelectionTable {
            declared: Vec::new(),
            numbers: HashMap::new(),
        };
        table.visit(root);
        // Declared in the order each selection was completed, the root
        // last; numbered the other way round.
        let last = table.declared.len() - 1;
        table.declared.reverse();
        for number in table.numbers.values_mut() {
            *number = last - *number;
        }
        table
    }

    /// Visits `selection` after the selections its fields select, and
    /// declares it unless an equal one is declared.
    fn visit(&mut self, selection: &'a NormalizationSelection) {
        for variant in &selection.variants {
            for field in &variant.fields {
                if let NormalizationKind::Linked {
                    selection: child, ..
                } = &field.kind
                {
                    self.visit(child);
                }
            }
        }
        let index = match self
            .declared
            .iter()
            .position(|declared| *declared == selection)
        {
            Some(index) => index,
            None => {
                self.declared.push(selection);
                self.declared.len() - 1
            }
        };
        self.numbers.insert(selection as *const _, index);
    }

    /// The declared selections with their numbers, the root first.
    pub fn declarations(&self) -> impl Iterator<Item = (usize, &'a NormalizationSelection)> + '_ {
        self.declared.iter().copied().enumerate()
    }

    /// The number of the declaration `selection`, a selection of the plan,
    /// refers to.
    pub fn number(&self, selection: &NormalizationSelection) -> usize {
        *self
            .numbers
            .get(&(selection as *const _))
            .expect("every selection of the plan is in its table")
    }
}
