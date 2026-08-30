# 批量下载公开术数资料：优先 PDF/DjVu/TXT/HTML，保留来源索引与失败日志。
$ErrorActionPreference = "Continue"

$Root = "E:\Thing\Fortune\资料库"
$IndexPath = Join-Path $Root "_下载索引.csv"
$FailPath = Join-Path $Root "_失败记录.csv"

function New-SafeName($name) {
  $invalid = [IO.Path]::GetInvalidFileNameChars() -join ''
  $pattern = "[{0}]" -f [Regex]::Escape($invalid)
  return (($name -replace $pattern, "_") -replace "\s+", " ").Trim()
}

function Ensure-Dir($path) {
  if (-not (Test-Path -LiteralPath $path)) {
    New-Item -ItemType Directory -Path $path | Out-Null
  }
}

function Write-Row($path, $row) {
  if (-not (Test-Path -LiteralPath $path)) {
    "time,title,source,url,file,status,note" | Set-Content -LiteralPath $path -Encoding UTF8
  }
  $line = @(
    (Get-Date).ToString("s"),
    ($row.title -replace '"', '""'),
    ($row.source -replace '"', '""'),
    ($row.url -replace '"', '""'),
    ($row.file -replace '"', '""'),
    ($row.status -replace '"', '""'),
    ($row.note -replace '"', '""')
  ) | ForEach-Object { '"' + $_ + '"' }
  Add-Content -LiteralPath $path -Value ($line -join ",") -Encoding UTF8
}

function Download-File($url, $dir, $fileName, $title, $source) {
  Ensure-Dir $dir
  $safe = New-SafeName $fileName
  $target = Join-Path $dir $safe
  if ((Test-Path -LiteralPath $target) -and ((Get-Item -LiteralPath $target).Length -gt 1024)) {
    Write-Host "SKIP $safe"
    Write-Row $IndexPath @{ title=$title; source=$source; url=$url; file=$target; status="skipped"; note="already exists" }
    return
  }

  Write-Host "GET  $safe"
  & curl.exe -L --fail --retry 1 --retry-delay 5 --retry-max-time 45 -C - -o $target $url
  if ($LASTEXITCODE -eq 0 -and (Test-Path -LiteralPath $target) -and ((Get-Item -LiteralPath $target).Length -gt 1024)) {
    Write-Row $IndexPath @{ title=$title; source=$source; url=$url; file=$target; status="ok"; note="" }
  } else {
    if (Test-Path -LiteralPath $target) { Remove-Item -LiteralPath $target -Force }
      Write-Row $FailPath @{ title=$title; source=$source; url=$url; file=$target; status="failed"; note="curl exit $LASTEXITCODE" }
  }
  Start-Sleep -Seconds 2
}

function Save-WebPage($url, $dir, $fileName, $title, $source) {
  Ensure-Dir $dir
  $target = Join-Path $dir (New-SafeName $fileName)
  if (Test-Path -LiteralPath $target) {
    Write-Host "SKIP $fileName"
    return
  }
  try {
    $resp = Invoke-WebRequest -Uri $url -Headers @{ "User-Agent"="Codex research downloader" } -TimeoutSec 60
    $resp.Content | Set-Content -LiteralPath $target -Encoding UTF8
    Write-Row $IndexPath @{ title=$title; source=$source; url=$url; file=$target; status="ok"; note="html/text saved" }
  } catch {
    Write-Row $FailPath @{ title=$title; source=$source; url=$url; file=$target; status="failed"; note=$_.Exception.Message }
  }
}

function Download-InternetArchiveItem($identifier, $category, $title) {
  $dir = Join-Path $Root $category
  $metaUrl = "https://archive.org/metadata/$identifier"
  try {
    $meta = Invoke-RestMethod -Uri $metaUrl -Headers @{ "User-Agent"="Codex research downloader" } -TimeoutSec 60
    $files = @($meta.files | Where-Object {
      ($_.name -match "\.(pdf|djvu|txt|epub)$") -or
      ($_.format -match "PDF|DjVu|EPUB|FULL TEXT")
    })
    foreach ($f in $files) {
      $name = [string]$f.name
      if ($name -match "_abbyy|_chocr|_hocr|_page_numbers|_meta|_files|_itemimage|_jp2|_scandata|_djvu.xml") { continue }
      $url = "https://archive.org/download/$identifier/$([Uri]::EscapeDataString($name).Replace('%2F','/'))"
      Download-File $url $dir "$identifier - $name" $title "Internet Archive"
    }
  } catch {
    Write-Row $FailPath @{ title=$title; source="Internet Archive"; url=$metaUrl; file=""; status="failed"; note=$_.Exception.Message }
  }
}

function Search-InternetArchive($query, $category) {
  $encoded = [Uri]::EscapeDataString("title:($query) AND mediatype:texts")
  $url = "https://archive.org/advancedsearch.php?q=$encoded&fl%5B%5D=identifier&fl%5B%5D=title&rows=25&page=1&output=json"
  try {
    $result = Invoke-RestMethod -Uri $url -Headers @{ "User-Agent"="Codex research downloader" } -TimeoutSec 60
    foreach ($doc in @($result.response.docs)) {
      if (-not $doc.identifier) { continue }
      Download-InternetArchiveItem $doc.identifier $category $doc.title
    }
  } catch {
    Write-Row $FailPath @{ title=$query; source="Internet Archive Search"; url=$url; file=""; status="failed"; note=$_.Exception.Message }
  }
}

function Download-CommonsCategory($categoryTitle, $category) {
  $dir = Join-Path $Root $category
  $cmcontinue = $null
  do {
    $base = "https://commons.wikimedia.org/w/api.php?action=query&format=json&list=categorymembers&cmtype=file&cmlimit=500&cmtitle=$([Uri]::EscapeDataString($categoryTitle))"
    if ($cmcontinue) { $base += "&cmcontinue=$([Uri]::EscapeDataString($cmcontinue))" }
    try {
      $data = Invoke-RestMethod -Uri $base -Headers @{ "User-Agent"="Codex research downloader" } -TimeoutSec 60
      $titles = @($data.query.categorymembers | ForEach-Object { $_.title })
      foreach ($t in $titles) {
        $fileName = ($t -replace "^File:", "")
        if ($fileName -notmatch "\.(pdf|djvu)$") { continue }
        $url = "https://commons.wikimedia.org/wiki/Special:Redirect/file/$([Uri]::EscapeDataString($fileName))"
        Download-File $url $dir $fileName $fileName "Wikimedia Commons"
      }
      $cmcontinue = $data.continue.cmcontinue
    } catch {
      Write-Row $FailPath @{ title=$categoryTitle; source="Wikimedia Commons"; url=$base; file=""; status="failed"; note=$_.Exception.Message }
      $cmcontinue = $null
    }
  } while ($cmcontinue)
}

Ensure-Dir $Root

$iaItems = @(
  @{ id="06066037.cn"; cat="八字子平\三命通会"; title="三命通会 卷一" },
  @{ id="06066038.cn"; cat="八字子平\三命通会"; title="三命通会 卷二" },
  @{ id="06056479.cn"; cat="八字子平\三命通会"; title="三命通会 卷三" },
  @{ id="06066044.cn"; cat="八字子平\三命通会"; title="三命通会 卷八" },
  @{ id="06056485.cn"; cat="八字子平\三命通会"; title="三命通会 卷九" },
  @{ id="06056487.cn"; cat="八字子平\三命通会"; title="三命通会 卷十一" },
  @{ id="06056488.cn"; cat="八字子平\三命通会"; title="三命通会 卷十二" },
  @{ id="02071812.cn"; cat="卜筮易占\周易"; title="周易正义 一" },
  @{ id="02094328.cn"; cat="卜筮易占\焦氏易林"; title="焦氏易林校略 八" }
)

foreach ($item in $iaItems) {
  Download-InternetArchiveItem $item.id $item.cat $item.title
}

# Internet Archive 公开搜索结果容易混入现代重排、网文存档或版权状态不明的材料。
# 这里先关闭自动搜索，只下载上方人工核对过的古籍条目；后续可把确认过的 identifier 加入 $iaItems。
$iaSearches = @()

foreach ($s in $iaSearches) {
  Search-InternetArchive $s.q $s.cat
}

$commonsCategories = @(
  @{ title="Category:增刪卜易"; cat="卜筮易占\增删卜易" },
  @{ title="Category:神相全編"; cat="相术\神相全编" },
  @{ title="Category:袁柳庄先生神相全編"; cat="相术\柳庄相法" },
  @{ title="Category:新刻東海王先生纂輯陽宅十書"; cat="堪舆择日\阳宅十书" },
  @{ title="Category:許眞君萬全玉匣記"; cat="堪舆择日\玉匣记" },
  @{ title="Category:增廣玉匣記家用秘書"; cat="堪舆择日\玉匣记" },
  @{ title="Category:淵海子平"; cat="八字子平\渊海子平" },
  @{ title="Category:子平真詮"; cat="八字子平\子平真诠" },
  @{ title="Category:增補星平會海命學全書"; cat="星命三式\星平会海" }
)

foreach ($c in $commonsCategories) {
  Download-CommonsCategory $c.title $c.cat
}

$webPages = @(
  @{ url="https://ctext.org/book-of-changes/zh"; cat="在线文本\CTP"; name="周易 - CTP.html"; title="周易" },
  @{ url="https://ctext.org/jiaoshi-yilin/zh"; cat="在线文本\CTP"; name="焦氏易林 - CTP.html"; title="焦氏易林" },
  @{ url="https://ctext.org/jingshi-yizhuan/zh"; cat="在线文本\CTP"; name="京氏易传 - CTP.html"; title="京氏易传" },
  @{ url="https://ctext.org/wiki.pl?if=gb&res=591203"; cat="在线文本\CTP"; name="火珠林 - CTP.html"; title="火珠林" },
  @{ url="https://ctext.org/wiki.pl?if=gb&res=454216"; cat="在线文本\CTP"; name="三命通会 - CTP.html"; title="三命通会" },
  @{ url="https://ctext.org/wiki.pl?chapter=974137&if=gb"; cat="在线文本\CTP"; name="子平真诠评注 - CTP.html"; title="子平真诠评注" },
  @{ url="https://ctext.org/wiki.pl?if=gb&res=507391"; cat="在线文本\CTP"; name="开元占经 - CTP.html"; title="开元占经" },
  @{ url="https://ctext.org/wiki.pl?if=gb&res=786762"; cat="在线文本\CTP"; name="乙巳占 - CTP.html"; title="乙巳占" },
  @{ url="https://ctext.org/wiki.pl?if=gb&res=981926"; cat="在线文本\CTP"; name="果老星宗 - CTP.html"; title="果老星宗" },
  @{ url="https://ctext.org/wiki.pl?if=gb&chapter=152581"; cat="在线文本\CTP"; name="星命总括 - CTP.html"; title="星命总括" },
  @{ url="https://ctext.org/wiki.pl?if=gb&res=602375"; cat="在线文本\CTP"; name="葬书 - CTP.html"; title="葬书" },
  @{ url="https://ctext.org/wiki.pl?if=gb&res=583881"; cat="在线文本\CTP"; name="协纪辨方书 - CTP.html"; title="协纪辨方书" },
  @{ url="https://ctext.org/wiki.pl?if=gb&res=694508"; cat="在线文本\CTP"; name="太乙金镜式经 - CTP.html"; title="太乙金镜式经" },
  @{ url="https://ctext.org/wiki.pl?if=gb&res=432738"; cat="在线文本\CTP"; name="黄帝龙首经 - CTP.html"; title="黄帝龙首经" },
  @{ url="https://ctext.org/wiki.pl?if=gb&res=624348"; cat="在线文本\CTP"; name="大六壬大全 - CTP.html"; title="大六壬大全" },
  @{ url="https://zh.wikisource.org/zh-hant/%E5%A2%9E%E5%88%AA%E5%8D%9C%E6%98%93"; cat="在线文本\维基文库"; name="增删卜易 - 维基文库.html"; title="增删卜易" },
  @{ url="https://zh.wikisource.org/wiki/%E4%B8%89%E5%91%BD%E9%80%9A%E6%9C%83_(%E5%9B%9B%E5%BA%AB%E5%85%A8%E6%9B%B8%E6%9C%AC)"; cat="在线文本\维基文库"; name="三命通会四库本 - 维基文库.html"; title="三命通会四库本" }
)

foreach ($p in $webPages) {
  Save-WebPage $p.url (Join-Path $Root $p.cat) $p.name $p.title "Web text"
}

Write-Host "DONE. Index: $IndexPath"
Write-Host "Failures: $FailPath"
