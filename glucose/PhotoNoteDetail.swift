import Photos
import SwiftUI

// MARK: - 전체 화면 사진 보기

/// 메모에 붙인 사진을 전체 화면으로 크게 보여준다. 핀치로 확대, 두 번 탭으로 확대/원래 크기 전환.
struct PhotoViewer: View {
    let assetIdentifier: String

    @Environment(\.dismiss) private var dismiss

    @State private var image: UIImage?
    @State private var scale: CGFloat = 1
    @State private var pinchBaseScale: CGFloat?

    private static let maxScale: CGFloat = 5

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            if let image {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFit()
                    .scaleEffect(scale)
                    .gesture(magnifyGesture)
                    .onTapGesture(count: 2) {
                        withAnimation(.snappy) {
                            scale = scale > 1 ? 1 : 2.5
                        }
                    }
            } else {
                ProgressView()
                    .tint(.white)
            }
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
        .task(id: assetIdentifier) {
            // 화면 크기에 맞춰 원본에 가까운 해상도로 불러온다.
            image = await PhotoAssetLoader.image(
                identifier: assetIdentifier,
                targetSize: CGSize(width: 2000, height: 2000),
                contentMode: .aspectFit)
        }
    }

    private var magnifyGesture: some Gesture {
        MagnifyGesture()
            .onChanged { value in
                let base = pinchBaseScale ?? scale
                if pinchBaseScale == nil { pinchBaseScale = base }
                scale = min(max(base * value.magnification, 1), Self.maxScale)
            }
            .onEnded { _ in
                pinchBaseScale = nil
            }
    }
}

// MARK: - 메모 수정 시트

/// 저장된 식사 메모의 내용과 탄수화물을 고치는 시트.
struct PhotoNoteEditSheet: View {
    let note: PhotoNote
    /// (메모, 탄수화물 g)
    let onSave: (String, Double?) -> Void

    @Environment(\.dismiss) private var dismiss

    @State private var memo: String
    @State private var carbsText: String
    @State private var showViewer = false

    init(note: PhotoNote, onSave: @escaping (String, Double?) -> Void) {
        self.note = note
        self.onSave = onSave
        _memo = State(initialValue: note.memo)
        _carbsText = State(initialValue: note.carbsGrams.map(PhotoNote.gramsText) ?? "")
    }

    /// 입력한 탄수화물(g). 숫자가 아니거나 0 이하이면 없는 것으로 본다.
    private var carbsGrams: Double? {
        guard let value = Double(carbsText.replacingOccurrences(of: ",", with: ".")),
              value > 0
        else { return nil }
        return value
    }

    var body: some View {
        NavigationStack {
            VStack(alignment: .leading, spacing: 12) {
                Text(timeText)
                    .font(.footnote)
                    .foregroundStyle(.secondary)

                if let assetIdentifier = note.assetIdentifier {
                    Button {
                        showViewer = true
                    } label: {
                        PhotoAssetImage(assetIdentifier: assetIdentifier)
                            .frame(height: 160)
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("사진 크게 보기")
                }

                TextField("메모 (예: 김치찌개, 라떼)", text: $memo, axis: .vertical)
                    .lineLimit(1...3)
                    .padding(10)
                    .background(Color(.secondarySystemGroupedBackground), in: .rect(cornerRadius: 10))

                HStack(spacing: 8) {
                    TextField("탄수화물 (선택)", text: $carbsText)
                        .keyboardType(.decimalPad)
                        .padding(10)
                        .background(
                            Color(.secondarySystemGroupedBackground), in: .rect(cornerRadius: 10))
                        .frame(maxWidth: 160)
                    Text("g")
                        .foregroundStyle(.secondary)
                }

                Text("탄수화물을 바꾸면 건강 앱 기록도 함께 바뀝니다.")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)

                Spacer()
            }
            .padding()
            .background(Color(.systemGroupedBackground))
            .navigationTitle("메모 수정")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("취소") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("저장") {
                        onSave(memo.trimmingCharacters(in: .whitespacesAndNewlines), carbsGrams)
                        dismiss()
                    }
                }
            }
        }
        .fullScreenCover(isPresented: $showViewer) {
            if let assetIdentifier = note.assetIdentifier {
                PhotoViewer(assetIdentifier: assetIdentifier)
            }
        }
    }

    private var timeText: String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "ko_KR")
        formatter.dateFormat = "M/d (E) a h:mm"
        return formatter.string(from: note.pointDate)
    }
}
