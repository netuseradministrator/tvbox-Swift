import SwiftUI

/// 首页 - 对应 Android 版 HomeActivity + UserFragment
struct HomeView: View {
    @StateObject private var viewModel = HomeViewModel()
    @StateObject private var apiConfig = ApiConfig.shared
    @EnvironmentObject var appState: AppState
    @State private var categoryScrollAnchorId: String?
    
    // 网格布局
    #if os(iOS)
    private let columns = [
        GridItem(.adaptive(minimum: 100, maximum: 140), spacing: 10)
    ]
    #else
    private let columns = [
        GridItem(.adaptive(minimum: 140, maximum: 180), spacing: 16)
    ]
    #endif
    
    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                // 顶部栏
                headerBar
                
                // 分类标签栏
                if !viewModel.sorts.isEmpty {
                    categoryTabBar
                }
                
                // 内容区
                contentArea
            }
            .background(AppTheme.primaryGradient)
        }
        .task {
            await viewModel.loadSorts()
        }
        .onChange(of: apiConfig.homeSourceBean?.cacheIdentifier) { _, _ in
            guard let source = apiConfig.homeSourceBean else { return }
            viewModel.switchSource(source)
        }
    }
    
    // MARK: - 顶部栏（源选择器）
    
    private var headerBar: some View {
        HStack(spacing: 12) {
            // 源切换按钮
            Menu {
                ForEach(apiConfig.sourceBeanList.filter { $0.isSupportedInSwift }) { source in
                    Button {
                        apiConfig.setHomeSource(source)
                        appState.currentSourceKey = source.key
                    } label: {
                        HStack {
                            Text(source.name)
                            if source.key == apiConfig.homeSourceBean?.key {
                                Image(systemName: "checkmark")
                            }
                        }
                    }
                }
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: "play.tv.fill")
                        .font(.system(size: 14))
                        .foregroundColor(.orange)
                    Text(apiConfig.homeSourceBean?.name ?? "TVBox")
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundColor(.white)
                        .lineLimit(1)
                    Image(systemName: "chevron.down")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundColor(.white.opacity(0.5))
                }
            }
            .menuStyle(.borderlessButton)
            .fixedSize()

            if viewModel.isRefreshing {
                ProgressView()
                    .controlSize(.small)
                    .tint(.orange)
            }
            
            Spacer()
        }
        .padding(.horizontal, 16)
        .padding(.top, 10)
        .padding(.bottom, 4)
    }
    
    // MARK: - 分类标签栏
    
    private var categoryTabBar: some View {
        ScrollViewReader { proxy in
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 0) {
                    ForEach(viewModel.sorts) { sort in
                        Button {
                            withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) {
                                viewModel.selectSort(sort)
                            }
                            categoryScrollAnchorId = sort.id
                            scrollCategoryBar(to: sort.id, proxy: proxy)
                        } label: {
                            VStack(spacing: 6) {
                                Text(sort.name)
                                    .font(.system(size: 14, weight: viewModel.selectedSort?.id == sort.id ? .bold : .regular))
                                    .foregroundColor(viewModel.selectedSort?.id == sort.id ? .white : .white.opacity(0.6))
                                
                                // 底部指示条
                                RoundedRectangle(cornerRadius: 1.5)
                                    .fill(Color.orange)
                                    .frame(width: 20, height: 3)
                                    .opacity(viewModel.selectedSort?.id == sort.id ? 1 : 0)
                            }
                            .padding(.horizontal, 14)
                            .padding(.vertical, 8)
                        }
                        .buttonStyle(.plain)
                        .id(sort.id)
                    }
                }
                .padding(.horizontal, 12)
            }
            .onAppear {
                syncCategoryScrollAnchorIfNeeded()
                scrollCategoryBar(to: categoryScrollAnchorId, proxy: proxy, animated: false)
            }
            .onChange(of: viewModel.sorts.map(\.id)) { oldValue, newValue in
                syncCategoryScrollAnchorIfNeeded()
                scrollCategoryBar(to: categoryScrollAnchorId, proxy: proxy, animated: false)
            }
            .onChange(of: viewModel.selectedSort?.id) { oldId, newId in
                guard let newId else { return }
                categoryScrollAnchorId = newId
                scrollCategoryBar(to: newId, proxy: proxy)
            }
        }
        .padding(.bottom, 4)
    }
    
    private func syncCategoryScrollAnchorIfNeeded() {
        guard !viewModel.sorts.isEmpty else {
            categoryScrollAnchorId = nil
            return
        }
        
        if let selectedId = viewModel.selectedSort?.id,
           viewModel.sorts.contains(where: { $0.id == selectedId }) {
            categoryScrollAnchorId = selectedId
            return
        }
        
        if let anchorId = categoryScrollAnchorId,
           viewModel.sorts.contains(where: { $0.id == anchorId }) {
            return
        }
        
        categoryScrollAnchorId = viewModel.sorts.first?.id
    }
    
    private func scrollCategoryBar(to id: String?, proxy: ScrollViewProxy, animated: Bool = true) {
        guard let id else { return }
        
        if animated {
            withAnimation(.easeInOut(duration: 0.2)) {
                proxy.scrollTo(id, anchor: .center)
            }
        } else {
            proxy.scrollTo(id, anchor: .center)
        }
    }
    
    // MARK: - 内容区

    private var displayedVideos: [Movie.Video] {
        viewModel.selectedSort?.id == "home" ? viewModel.homeVideos : viewModel.categoryVideos
    }
    
    private var contentArea: some View {
        Group {
            if viewModel.isLoading && displayedVideos.isEmpty {
                VStack {
                    Spacer()
                    ProgressView()
                        .scaleEffect(1.5)
                        .tint(.orange)
                    Text("正在加载数据源...")
                        .font(.subheadline)
                        .foregroundColor(.secondary)
                        .padding(.top, 12)
                    Spacer()
                }
            } else if let error = viewModel.errorMessage, displayedVideos.isEmpty {
                VStack(spacing: 12) {
                    Spacer()
                    Image(systemName: "exclamationmark.triangle")
                        .font(.largeTitle)
                        .foregroundColor(.orange)
                    Text(error)
                        .font(.subheadline)
                        .foregroundColor(.secondary)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 40)
                    Button("重试") {
                        Task { await viewModel.refresh() }
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(.orange)
                    Spacer()
                }
            } else if displayedVideos.isEmpty {
                VStack {
                    Spacer()
                    Text("暂无内容")
                        .foregroundColor(.secondary)
                    Spacer()
                }
            } else {
                ScrollView {
                    LazyVGrid(columns: columns, spacing: 16) {
                        ForEach(displayedVideos) { video in
                            NavigationLink(value: video) {
                                VodCardView(video: video)
                            }
                            #if os(iOS)
                            .buttonStyle(VodCardPressStyle())
                            #else
                            .buttonStyle(.plain)
                            #endif
                            .onAppear {
                                Task { await viewModel.loadMoreIfNeeded(currentItem: video) }
                            }
                        }
                    }
                    .padding(.horizontal, 20)
                    .padding(.vertical, 12)

                    if viewModel.isLoadingMore {
                        ProgressView()
                            .padding()
                    }
                }
                .refreshable {
                    await viewModel.refresh()
                }
            }
        }
        .navigationDestination(for: Movie.Video.self) { video in
            DetailView(video: video)
        }
    }
}

