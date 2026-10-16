import SwiftUI

/// 사진이 붙은 식사 메모 전체를 날짜별 그리드로 둘러보는 갤러리.
/// 사진을 탭하면 전체 화면 브라우저에서 좌우로 넘겨 볼 수 있다.
struct PhotoGalleryView: View {
    let photoStore: PhotoNoteStore

    @State private var pagerTarget: PagerTarget?

    private struct PagerTarget: Identifiable {
        let startIndex: Int
        var id: Int { startIndex }
    }

    /// 최신 식사가 위로 오도록 정렬한 사진 메모. 브라우저의 넘김 순서도 이와 같다.
    private var photoNotes: [PhotoNote] {
        photoStore.notes
            .filter { $0.assetIdentifier != nil }
            .sorted { $0.pointDate > $1.pointDate }
    }

    private var sections: [(day: Date, items: [PhotoNote])] {
        let calendar = Calendar.current
        let grouped = Dictionary(grouping: photoNotes) { calendar.startOfDay(for: $0.pointDate) }
        return grouped
            .map { (day: $0.key, items: $0.value) }
            .sorted { $0.day > $1.day }
    }

    var body: some View {
        Group {
            if photoNotes.isEmpty {
                ContentUnavailableView(
                    "사진 없음",
                    systemImage: "photo.on.rectangle",
                    description: Text("아직 사진이 붙은 식사 메모가 없습니다."))
            } else {
                grid
            }
        }
        .background(Color(.systemGroupedBackground))
        .navigationTitle("식사 사진 \(photoNotes.count)장")
        .navigationBarTitleDisplayMode(.inline)
        .fullScreenCover(item: $pagerTarget) { target in
            PhotoPagerViewer(notes: photoNotes, startIndex: target.startIndex)
        }
    }

    private var grid: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 8, pinnedViews: .sectionHeaders) {
                ForEach(sections, id: \.day) { section in
                    Section {
                        LazyVGrid(
                            columns: Array(repeating: GridItem(.flexible(), spacing: 4), count: 3),
                            spacing: 4
                        ) {
                            ForEach(section.items) { note in
                                cell(note)
                            }
                        }
                        .padding(.horizontal)
                    } header: {
                        Text(Self.dayLabel(section.day))
                            .font(.subheadline.weight(.semibold))
                            .padding(.horizontal)
                            .padding(.vertical, 6)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(Color(.systemGroupedBackground))
                    }
                }
            }
            .padding(.vertical, 8)
        }
    }

    private func cell(_ note: PhotoNote) -> some View {
        Button {
            if let index = photoNotes.firstIndex(where: { $0.id == note.id }) {
                pagerTarget = PagerTarget(startIndex: index)
            }
        } label: {
            PhotoAssetImage(
                assetIdentifier: note.assetIdentifier ?? "",
                cloudIdentifier: note.assetCloudIdentifier)
            .aspectRatio(1, contentMode: .fit)
            .overlay(alignment: .bottomLeading) {
                Text(Self.timeLabel(note.pointDate))
                    .font(.caption2.weight(.medium))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 5)
                    .padding(.vertical, 2)
                    .background(.black.opacity(0.45), in: .capsule)
                    .padding(4)
            }
        }
        .buttonStyle(.plain)
        .accessibilityLabel("사진 크게 보기")
    }

    private static func dayLabel(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "ko_KR")
        formatter.dateFormat = "M월 d일 (E)"
        return formatter.string(from: date)
    }

    private static func timeLabel(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "ko_KR")
        formatter.dateFormat = "a h:mm"
        return formatter.string(from: date)
    }
}

// MARK: - 좌우로 넘겨 보는 전체 화면 브라우저

/// 사진 메모들을 전체 화면에서 좌우 스와이프로 넘겨 본다.
/// 아래에는 측정 시각·메모 캡션과 몇 번째인지 표시한다.
struct PhotoPagerViewer: View {
    let notes: [PhotoNote]

    @Environment(\.dismiss) private var dismiss
    @State private var index: Int

    init(notes: [PhotoNote], startIndex: Int) {
        self.notes = notes
        _index = State(initialValue: min(max(startIndex, 0), max(notes.count - 1, 0)))
    }

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            TabView(selection: $index) {
                ForEach(Array(notes.enumerated()), id: \.element.id) { offset, note in
                    ZoomableAssetImage(
                        assetIdentifier: note.assetIdentifier ?? "",
                        cloudIdentifier: note.assetCloudIdentifier)
                    .tag(offset)
                }
            }
            .tabViewStyle(.page(indexDisplayMode: .never))
            .ignoresSafeArea()
        }
        .overlay(alignment: .topTrailing) {
            Button {
                dismiss()
            } label: {
                Image(systemName: "xmark")
                    .font(.headline)
                    .foregroundStyle(.white)
                    .frame(width: 36, height: 36)
                    .background(.black.opacity(0.5), in: .circle)
            }
            .padding()
            .accessibilityLabel("닫기")
        }
        .overlay(alignment: .bottom) {
            caption
        }
    }

    private var caption: some View {
        let note = notes[index]
        return VStack(spacing: 4) {
            Text(Self.dateTimeLabel(note.pointDate))
                .font(.subheadline.weight(.semibold))
            if !note.memo.isEmpty {
                Text(note.memo)
                    .font(.caption)
                    .lineLimit(2)
            }
            Text("\(index + 1) / \(notes.count)")
                .font(.caption2)
                .foregroundStyle(.white.opacity(0.7))
        }
        .foregroundStyle(.white)
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(.black.opacity(0.45), in: .rect(cornerRadius: 12))
        .padding(.bottom, 24)
        .padding(.horizontal)
    }

    private static func dateTimeLabel(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "ko_KR")
        formatter.dateFormat = "M/d (E) a h:mm"
        return formatter.string(from: date)
    }
}
