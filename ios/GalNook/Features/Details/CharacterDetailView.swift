import SwiftUI

struct CharacterDetailView: View {
    let character: GameCharacter

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                RemoteImage(url: character.imageURL)
                    .frame(maxWidth: 360)
                    .frame(minHeight: 260, maxHeight: 480)
                    .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
                    .frame(maxWidth: .infinity)
                VStack(alignment: .leading, spacing: 8) {
                    Text(character.name).font(.title.bold())
                    if let original = character.originalName, original != character.name {
                        Text(original).foregroundStyle(.secondary)
                    }
                    if let role = character.role { Label(role, systemImage: "person") }
                }
                .frame(maxWidth: .infinity, alignment: .leading)

                let facts = [
                    ("生日", character.birthday),
                    ("血型", character.bloodType),
                    ("身高", character.height),
                    ("三围", character.measurements),
                    ("声优", character.voiceActor)
                ].compactMap { item -> (String, String)? in
                    guard let value = item.1, !value.isEmpty else { return nil }
                    return (item.0, value)
                }
                if !facts.isEmpty {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 140), alignment: .leading)], spacing: 14) {
                        ForEach(facts, id: \.0) { fact in
                            VStack(alignment: .leading) {
                                Text(fact.0).font(.caption).foregroundStyle(.secondary)
                                Text(fact.1).font(.body.weight(.medium))
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding()
                            .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 12))
                        }
                    }
                }
                if let description = character.description, !description.isEmpty {
                    Text("角色介绍").font(.title3.bold())
                    Text(description).lineSpacing(6).textSelection(.enabled)
                }
            }
            .padding()
            .frame(maxWidth: 800)
            .frame(maxWidth: .infinity)
        }
        .background(Color(.systemGroupedBackground))
        .navigationTitle(character.name)
        .navigationBarTitleDisplayMode(.inline)
    }
}
