import AppIntents
import RuntilCore

/// A plan, as Siri sees it.
///
/// The display name is the plan's own name, so "start a Zone 2 run/walk" matches what you
/// called it on the phone rather than some parallel vocabulary you'd have to remember.
struct PlanEntity: AppEntity {
    let id: UUID
    let name: String

    static var typeDisplayRepresentation: TypeDisplayRepresentation { "Plan" }

    var displayRepresentation: DisplayRepresentation {
        DisplayRepresentation(title: "\(name)")
    }

    static var defaultQuery = PlanQuery()

    init(plan: WorkoutPlan) {
        id = plan.id
        name = plan.name
    }
}

struct PlanQuery: EntityQuery {
    /// Reads the library straight off disk rather than through `PlanStore`, since an intent
    /// can be resolved before any UI exists.
    func entities(for identifiers: [UUID]) async throws -> [PlanEntity] {
        PlanFile.load()
            .filter { identifiers.contains($0.id) }
            .map(PlanEntity.init)
    }

    func suggestedEntities() async throws -> [PlanEntity] {
        PlanFile.load().map(PlanEntity.init)
    }

    func defaultResult() async -> PlanEntity? {
        PlanFile.load().first.map(PlanEntity.init)
    }
}

extension PlanQuery: EntityStringQuery {
    /// Lets Siri match a spoken plan name loosely — "zone two" should find "Zone 2 run/walk"
    /// without you having to say the whole thing.
    func entities(matching string: String) async throws -> [PlanEntity] {
        let needle = string.folding(options: .diacriticInsensitive, locale: .current).lowercased()
        return PlanFile.load()
            .filter { $0.name.lowercased().contains(needle) }
            .map(PlanEntity.init)
    }
}
