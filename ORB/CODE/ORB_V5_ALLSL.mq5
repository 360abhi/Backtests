// ORB V3 performance revision. Broker-clock, market touch entries unchanged.
// UI disabled in nonvisual tests; cached session times; work only when needed.
// Compile in MetaEditor. No native compilation has been performed here.
// One successful entry per broker day; no reversal, TP or trailing stop.
// Defaults: 03:05-06:05 range; 07:00 <= entry < 18:55; close 18:55.
// SL is anchored to the executable entry QUOTE, not the breakout level.
// Actual fills may slip; risk is a pre-trade estimate before commissions.
#property copyright "2026, Built for Abhishek"
#property version "3.12"
#property strict
#include <Trade/Trade.mqh>

enum ENUM_RANGE_MEASURE { RANGE_ATR=0, RANGE_PERCENT=1 };
enum ENUM_STOP_TYPE { STOP_ATR=0, STOP_PRICE_PERCENT=1 };
input group "01 - Range times: BROKER SERVER CLOCK"
input int Range_Start_Hour=3;
input int Range_Start_Minute=5;
input int Range_End_Hour=6;
input int Range_End_Minute=5;
input group "02 - Entry window and daily exit: BROKER CLOCK"
input bool Use_Entry_Time_Filter=false;
input int Entry_Start_Hour=7;
input int Entry_Start_Minute=0;
input int Entry_End_Hour=18;
input int Entry_End_Minute=55;
input int Trade_Close_Hour=18;
input int Trade_Close_Minute=55;
input group "03 - Single master range filter"
input bool Use_Range_Filter=false; // OFF bypasses ALL range-size filters
input ENUM_RANGE_MEASURE Range_Filter_Measure=RANGE_ATR;
input double Min_Range_ATR=0.00;
input double Max_Range_ATR=0.60;
input double Min_Range_Percent=0.15;
input double Max_Range_Percent=1.00;
input group "04 - Stop type and breakout buffer"
input ENUM_STOP_TYPE Stop_Type=STOP_ATR; // STOP_ATR or STOP_PRICE_PERCENT
input ENUM_TIMEFRAMES Reference_ATR_Timeframe=PERIOD_D1;
input int Reference_ATR_Period=14;
input double Stop_ATR_Mult=0.25; // Used only when Stop_Type=STOP_ATR
input double Stop_Price_Percent=1.00; // Used only when Stop_Type=STOP_PRICE_PERCENT; 1.00 = 1% of entry price
input ENUM_TIMEFRAMES Buffer_ATR_Timeframe=PERIOD_M5;
input int Buffer_ATR_Period=14;
input double ATR_Buffer_Mult=0.05; // 0 disables buffer; not a range filter
input bool Allow_Long=true;
input bool Allow_Short=true;
input group "05 - Position size"
input double Risk_Percent=0.50; // Percent of current BALANCE, editable
input bool Use_Fixed_Lot=false;
input double Fixed_Lot=0.10;
input group "06 - Execution and data"
input ulong Magic_Number=325070;
input int Slippage_Points=20;
input int Max_Spread_Points=0; // 0 = disabled; no hidden ATR spread limit
input int Retry_Seconds=5;
input bool Require_Every_M1_Bar=false; // false accepts absent no-tick minutes, with warning
input group "07 - Display and diagnostics"
input bool Draw_Range=true;
input bool Enable_Logs=true;
input int Log_Repeat_Seconds=300;
input int Panel_Refresh_Seconds=5;
input bool Keep_Historical_Ranges=false; // draw current day only by default

CTrade trade;
int stopHandle=INVALID_HANDLE,bufferHandle=INVALID_HANDLE;
datetime day=0,rangeStart=0,rangeEnd=0,closeTime=0;
datetime lastRangeAttempt=0,lastEntryAttempt=0,lastExitAttempt=0,lastLog=0;
bool ready=false,rangePass=false,traded=false,historyReady=false;
bool unresolvedRequest=false;
ulong pendingOrder=0;
double high=0,low=0,buyLine=0,sellLine=0,stopATR=0;
string status="",prefix="";
datetime entryStart=0,entryEnd=0,lastPanel=0,lastReconcile=0;
bool visuals=false,overduePosition=false;

bool StateDue(string key)
{
   return key!=status || TimeCurrent()-lastLog>=Log_Repeat_Seconds;
}
void RefreshOverduePosition()
{
   overduePosition=false;
   for(int i=PositionsTotal()-1;i>=0;i--)
   {
      if(PositionGetTicket(i)==0 || PositionGetString(POSITION_SYMBOL)!=_Symbol ||
         (ulong)PositionGetInteger(POSITION_MAGIC)!=Magic_Number)continue;
      if((datetime)PositionGetInteger(POSITION_TIME)<day)
      { overduePosition=true;return; }
   }
}
void UpdatePanel()
{
   if(!visuals || TimeCurrent()-lastPanel<Panel_Refresh_Seconds)return;
   lastPanel=TimeCurrent();
   Comment("ORB V3 Fast | ",status,"\nBroker: ",TimeToString(TimeCurrent(),TIME_DATE|TIME_SECONDS),
      "\nRange filter: ",Use_Range_Filter?"ON":"OFF"," | risk: ",DoubleToString(Risk_Percent,2),"%",
      "\nStop: ",Stop_Type==STOP_ATR ? "ATR" : "PRICE %"," | ATR x ",DoubleToString(Stop_ATR_Mult,2),
      " | Price % ",DoubleToString(Stop_Price_Percent,2),
      "\nBuy: ",DoubleToString(buyLine,_Digits)," Sell: ",DoubleToString(sellLine,_Digits));
}

// 1. Clock, reporting, restart recovery.
int Minutes(int h,int m) { return h*60+m; }
bool ValidTime(int h,int m) { return h>=0 && h<24 && m>=0 && m<60; }
bool ReferenceATRNeeded()
{
   return Stop_Type==STOP_ATR || (Use_Range_Filter && Range_Filter_Measure==RANGE_ATR);
}
datetime DayStart(datetime now)
{
   MqlDateTime d; TimeToStruct(now,d); d.hour=0;d.min=0;d.sec=0;
   return StructToTime(d);
}
void Log(string s) { if(Enable_Logs) Print("[ORB V3] ",TimeToString(TimeCurrent(),TIME_DATE|TIME_SECONDS)," ",s); }
void State(string key,string detail="")
{
   if(key!=status || TimeCurrent()-lastLog>=Log_Repeat_Seconds)
   { Log(key+" "+detail); status=key;lastLog=TimeCurrent(); }
}
bool RestoreTrades()
{
   if(!HistorySelect(day,TimeCurrent())) { State("HISTORY_NOT_READY");return false; }
   // Never clear a confirmed local fill while account history catches up.
   for(int i=0;i<HistoryDealsTotal();i++)
   {
      ulong id=HistoryDealGetTicket(i);
      if(id==0 || HistoryDealGetString(id,DEAL_SYMBOL)!=_Symbol ||
         (ulong)HistoryDealGetInteger(id,DEAL_MAGIC)!=Magic_Number) continue;
      long en=HistoryDealGetInteger(id,DEAL_ENTRY);
      if(en==DEAL_ENTRY_IN || en==DEAL_ENTRY_INOUT) { traded=true;break; }
   }
   return true;
}
void ResetDay()
{
   datetime now=TimeCurrent();
   if(day!=0 && now>=day && now<day+86400)return; // no struct conversion on ordinary ticks
   datetime d=DayStart(now);
   if(visuals && !Keep_Historical_Ranges && day!=0)
   {
      string old=prefix+IntegerToString((long)day);
      ObjectDelete(0,old+"R");ObjectDelete(0,old+"B");ObjectDelete(0,old+"S");
   }
   day=d;ready=false;rangePass=false;traded=false;historyReady=false;
   high=0;low=0;buyLine=0;sellLine=0;stopATR=0;lastRangeAttempt=0;
   rangeStart=day+Minutes(Range_Start_Hour,Range_Start_Minute)*60;
   rangeEnd=day+Minutes(Range_End_Hour,Range_End_Minute)*60;
   closeTime=day+Minutes(Trade_Close_Hour,Trade_Close_Minute)*60;
   entryStart=rangeEnd;entryEnd=closeTime;
   if(Use_Entry_Time_Filter)
   {
      datetime requested=day+Minutes(Entry_Start_Hour,Entry_Start_Minute)*60;
      datetime finish=day+Minutes(Entry_End_Hour,Entry_End_Minute)*60;
      if(requested>entryStart)entryStart=requested;
      if(finish<entryEnd)entryEnd=finish;
   }
   RefreshOverduePosition();
   historyReady=RestoreTrades();
   Log("NEW_DAY range="+TimeToString(rangeStart,TIME_MINUTES)+"-"+
       TimeToString(rangeEnd,TIME_MINUTES)+" range_filter="+(Use_Range_Filter?"ON":"OFF"));
}
bool ATRBefore(int handle,ENUM_TIMEFRAMES tf,datetime boundary,double &value)
{
   int bar=iBarShift(_Symbol,tf,boundary,false);
   if(bar<0)return false;
   double a[1];
   // Exclude the bar containing the boundary: never read future/completing ATR.
   if(CopyBuffer(handle,0,bar+1,1,a)!=1 || !MathIsValidNumber(a[0]) || a[0]<=0)return false;
   value=a[0];return true;
}
double TickSize() { return SymbolInfoDouble(_Symbol,SYMBOL_TRADE_TICK_SIZE); }
double RoundPrice(double p,bool up)
{
   double ts=TickSize();if(ts<=0)return 0;
   return NormalizeDouble((up?MathCeil(p/ts-1e-9):MathFloor(p/ts+1e-9))*ts,_Digits);
}
void DrawLevels()
{
   if(!visuals)return;
   string stem=prefix+IntegerToString((long)day);
   ObjectCreate(0,stem+"R",OBJ_RECTANGLE,0,rangeStart,high,rangeEnd,low);
   ObjectSetInteger(0,stem+"R",OBJPROP_COLOR,clrDarkGoldenrod);
   ObjectSetInteger(0,stem+"R",OBJPROP_FILL,true);
   ObjectSetInteger(0,stem+"R",OBJPROP_BACK,true);
   ObjectCreate(0,stem+"B",OBJ_TREND,0,rangeEnd,buyLine,closeTime,buyLine);
   ObjectSetInteger(0,stem+"B",OBJPROP_COLOR,clrLimeGreen);
   ObjectSetInteger(0,stem+"B",OBJPROP_RAY_RIGHT,false);
   ObjectCreate(0,stem+"S",OBJ_TREND,0,rangeEnd,sellLine,closeTime,sellLine);
   ObjectSetInteger(0,stem+"S",OBJPROP_COLOR,clrTomato);
   ObjectSetInteger(0,stem+"S",OBJPROP_RAY_RIGHT,false);
   ChartRedraw();
}

// 2. Build the completed opening range independently of entry eligibility.
bool PrepareRange()
{
   if(ready)return true;
   if(TimeCurrent()<rangeEnd) { State("BUILDING_RANGE");return false; }
   if(TimeCurrent()-lastRangeAttempt<Retry_Seconds)return false;
   lastRangeAttempt=TimeCurrent();
   MqlRates bars[];ArraySetAsSeries(bars,false);
   int n=CopyRates(_Symbol,PERIOD_M1,rangeStart,rangeEnd-1,bars);
   if(n<=0 || !SeriesInfoInteger(_Symbol,PERIOD_M1,SERIES_SYNCHRONIZED))
   { State("M1_HISTORY_NOT_READY",IntegerToString(GetLastError()));return false; }
   datetime oldest=(datetime)SeriesInfoInteger(_Symbol,PERIOD_M1,SERIES_FIRSTDATE);
   if(oldest==0 || oldest>rangeStart)
   { State("M1_HISTORY_STARTS_TOO_LATE");return false; }
   int expected=(int)((rangeEnd-rangeStart)/60);
   bool complete=n==expected;
   high=-DBL_MAX;low=DBL_MAX;
   for(int i=0;i<n;i++)
   {
      if(bars[i].time<rangeStart || bars[i].time>=rangeEnd ||
         bars[i].high<bars[i].low || bars[i].low<=0)
      { State("INVALID_RANGE_BAR");return false; }
      if(i>0 && bars[i].time<=bars[i-1].time) { State("UNORDERED_RANGE_BARS");return false; }
      if(bars[i].time!=rangeStart+i*60)complete=false;
      high=MathMax(high,bars[i].high);low=MathMin(low,bars[i].low);
   }
   if(!complete && Require_Every_M1_Bar)
   { State("INCOMPLETE_M1_RANGE",StringFormat("bars=%d expected=%d strict=true",n,expected));return false; }
   if(high<=low) { State("ZERO_RANGE");return false; }
   if(ReferenceATRNeeded())
   {
      if(!ATRBefore(stopHandle,Reference_ATR_Timeframe,rangeEnd,stopATR))
      { State("REFERENCE_ATR_NOT_READY");return false; }
   }
   else stopATR=0;
   double bufferATR=0;
   if(ATR_Buffer_Mult>0 && !ATRBefore(bufferHandle,Buffer_ATR_Timeframe,rangeStart,bufferATR))
   { State("BUFFER_ATR_NOT_READY");return false; }
   buyLine=RoundPrice(high+ATR_Buffer_Mult*bufferATR,true);
   sellLine=RoundPrice(low-ATR_Buffer_Mult*bufferATR,false);
   if(buyLine<=sellLine || sellLine<=0) { State("INVALID_BREAKOUT_LEVELS");return false; }
   double ratio=(stopATR>0 ? (high-low)/stopATR : 0.0);
   double percent=100*(high-low)/((high+low)/2);
   rangePass=true;
   if(Use_Range_Filter)
      rangePass=Range_Filter_Measure==RANGE_ATR ?
         (stopATR>0 && ratio>=Min_Range_ATR && ratio<=Max_Range_ATR) :
         (percent>=Min_Range_Percent && percent<=Max_Range_Percent);
   ready=true;
   if(!complete)Log(StringFormat("M1_GAPS_ACCEPTED bars=%d expected=%d first=%s last=%s. Check historical data; no bars invented.",n,expected,TimeToString(bars[0].time,TIME_MINUTES),TimeToString(bars[n-1].time,TIME_MINUTES)));
   Log(StringFormat("RANGE_READY high=%.5f low=%.5f buy=%.5f sell=%.5f ATR=%.5f widthATR=%.4f widthPct=%.4f filter=%s result=%s",high,low,buyLine,sellLine,stopATR,ratio,percent,Use_Range_Filter?"ON":"OFF",rangePass?"PASS":"FAIL"));
   DrawLevels();return true;
}

// 3. Positions and daily exits. These run before any entry gate.
bool SymbolBusy()
{
   for(int i=PositionsTotal()-1;i>=0;i--)
      if(PositionGetTicket(i)>0 && PositionGetString(POSITION_SYMBOL)==_Symbol)return true;
   for(int i=OrdersTotal()-1;i>=0;i--)
      if(OrderGetTicket(i)>0 && OrderGetString(ORDER_SYMBOL)==_Symbol)return true;
   return false;
}
void CheckExits()
{
   datetime now=TimeCurrent();
   if(now<closeTime && !overduePosition)return; // nothing can expire yet
   if(PositionsTotal()==0) { overduePosition=false;return; }
   if(now-lastExitAttempt<Retry_Seconds)return;
   for(int i=PositionsTotal()-1;i>=0;i--)
   {
      ulong ticket=PositionGetTicket(i);
      if(ticket==0 || PositionGetString(POSITION_SYMBOL)!=_Symbol ||
         (ulong)PositionGetInteger(POSITION_MAGIC)!=Magic_Number)continue;
      datetime opened=(datetime)PositionGetInteger(POSITION_TIME);
      if(now<closeTime && DayStart(opened)>=day)continue;
      lastExitAttempt=now;
      bool ok=trade.PositionClose(ticket);
      Log(StringFormat("CLOSE ticket=%I64u ok=%s code=%u %s",ticket,ok?"true":"false",trade.ResultRetcode(),trade.ResultRetcodeDescription()));
   }
}
void ReconcileRequest()
{
   if(!unresolvedRequest)return;
   if(TimeCurrent()-lastReconcile<Retry_Seconds)return;
   lastReconcile=TimeCurrent();
   historyReady=RestoreTrades();
   if(traded) { unresolvedRequest=false;pendingOrder=0;return; }
   if(pendingOrder>0 && HistoryOrderSelect(pendingOrder))
   {
      long s=HistoryOrderGetInteger(pendingOrder,ORDER_STATE);
      if(s==ORDER_STATE_FILLED)
      {
         datetime filled=(datetime)HistoryOrderGetInteger(pendingOrder,ORDER_TIME_DONE);
         if(DayStart(filled)==day)traded=true;
         unresolvedRequest=false;pendingOrder=0;return;
      }
      if(s==ORDER_STATE_CANCELED || s==ORDER_STATE_REJECTED || s==ORDER_STATE_EXPIRED)
      { Log("ORDER_ENDED_WITHOUT_FILL; retries enabled");unresolvedRequest=false;pendingOrder=0; }
   }
   // Unknown timeout outcomes stay locked to prevent duplicate market orders.
}

// 4. Lots rounded DOWN. Never force minimum lot above the risk budget.
double LotsForStop(bool buy,double entry,double sl)
{
   double vmin=SymbolInfoDouble(_Symbol,SYMBOL_VOLUME_MIN);
   double vmax=SymbolInfoDouble(_Symbol,SYMBOL_VOLUME_MAX);
   double step=SymbolInfoDouble(_Symbol,SYMBOL_VOLUME_STEP);
   if(vmin<=0 || vmax<vmin || step<=0) { State("INVALID_VOLUME_SPEC");return 0; }
   double raw=Fixed_Lot,loss=0,budget=AccountInfoDouble(ACCOUNT_BALANCE)*Risk_Percent/100;
   ENUM_ORDER_TYPE type=buy?ORDER_TYPE_BUY:ORDER_TYPE_SELL;
   if(!Use_Fixed_Lot)
   {
      if(!OrderCalcProfit(type,_Symbol,vmin,entry,sl,loss) || loss>=0)
      { State("PROFIT_CALC_FAILED",IntegerToString(GetLastError()));return 0; }
      raw=budget/(MathAbs(loss)/vmin);
   }
   double vol=NormalizeDouble(MathFloor(MathMin(raw,vmax)/step+1e-9)*step,8);
   if(vol<vmin-1e-9)
   { State("LOT_BELOW_MINIMUM",StringFormat("raw=%.8f min=%.8f step=%.8f riskMoney=%.2f",raw,vmin,step,budget));return 0; }
   double margin=0;
   if(!OrderCalcMargin(type,_Symbol,vol,entry,margin)) { State("MARGIN_CALC_FAILED");return 0; }
   if(margin>AccountInfoDouble(ACCOUNT_MARGIN_FREE))
   { State("INSUFFICIENT_MARGIN",StringFormat("need=%.2f free=%.2f",margin,AccountInfoDouble(ACCOUNT_MARGIN_FREE)));return 0; }
   return vol;
}
void OpenTrade(bool buy,MqlTick &q)
{
   if(TimeCurrent()-lastEntryAttempt<Retry_Seconds)return;
   double entry=buy?q.ask:q.bid;
   double stopDistance=0;
   if(Stop_Type==STOP_ATR)
   {
      if(stopATR<=0) { State("STOP_ATR_NOT_READY");return; }
      stopDistance=Stop_ATR_Mult*stopATR;
   }
   else
      stopDistance=entry*Stop_Price_Percent/100.0;

   double sl=RoundPrice(entry+(buy?-1:1)*stopDistance,!buy);
   double minimum=SymbolInfoInteger(_Symbol,SYMBOL_TRADE_STOPS_LEVEL)*_Point;
   if(sl<=0 || (buy ? sl>=q.bid || q.bid-sl<minimum : sl<=q.ask || sl-q.ask<minimum))
   { State("STOP_TOO_CLOSE",StringFormat("entry=%.5f SL=%.5f bid=%.5f ask=%.5f minimum=%.5f",entry,sl,q.bid,q.ask,minimum));return; }
   double vol=LotsForStop(buy,entry,sl);if(vol<=0)return;
   lastEntryAttempt=TimeCurrent();
   bool ok=buy?trade.Buy(vol,_Symbol,0,sl,0,"ORB V3 touch"):
               trade.Sell(vol,_Symbol,0,sl,0,"ORB V3 touch");
   uint code=trade.ResultRetcode();
   Log(StringFormat("ORDER %s lots=%.8f quote=%.5f SL=%.5f bid=%.5f ask=%.5f code=%u %s",buy?"BUY":"SELL",vol,entry,sl,q.bid,q.ask,code,trade.ResultRetcodeDescription()));
   if(ok && (code==TRADE_RETCODE_DONE || code==TRADE_RETCODE_DONE_PARTIAL))
   { traded=true;Log(StringFormat("ENTRY_CONFIRMED deal=%I64u fill=%.5f",trade.ResultDeal(),trade.ResultPrice())); }
   else if(code==TRADE_RETCODE_PLACED || code==TRADE_RETCODE_TIMEOUT)
   { unresolvedRequest=true;pendingOrder=trade.ResultOrder();Log("AWAITING_ORDER_RESOLUTION; no duplicate retry"); }
   // Explicit rejection does NOT consume the day; eligible signals retry.
}

// 5. EVERY-TICK level check. A pre-window breakout remains eligible at start.
void CheckEntries()
{
   datetime now=TimeCurrent();MqlDateTime dt;TimeToStruct(now,dt);
   if(dt.day_of_week==0 || dt.day_of_week==6) { State("WEEKEND");return; }
   if(now<entryStart) { if(StateDue("BEFORE_ENTRY_WINDOW"))State("BEFORE_ENTRY_WINDOW",TimeToString(entryStart,TIME_MINUTES));return; }
   if(now>=entryEnd) { if(StateDue("ENTRY_WINDOW_CLOSED"))State("ENTRY_WINDOW_CLOSED",TimeToString(entryEnd,TIME_MINUTES));return; }
   if(!ready) { State("RANGE_NOT_READY");return; }
   if(!rangePass) { State("RANGE_FILTER_REJECTED");return; }
   if(!historyReady) { historyReady=RestoreTrades();if(!historyReady)return; }
   if(traded) { State("ALREADY_TRADED_TODAY");return; }
   if(unresolvedRequest) { State("AWAITING_ORDER_RESOLUTION");return; }
   MqlTick q;if(!SymbolInfoTick(_Symbol,q) || q.bid<=0 || q.ask<q.bid) { State("INVALID_QUOTE");return; }
   if(Max_Spread_Points>0 && q.ask-q.bid>Max_Spread_Points*_Point)
   { State("SPREAD_LIMIT",DoubleToString((q.ask-q.bid)/_Point,1));return; }
   bool buy=Allow_Long && q.ask>=buyLine;
   bool sell=Allow_Short && q.bid<=sellLine;
   if(buy && sell) { State("SPREAD_SPANS_BOTH_LINES");return; }
   if(!buy && !sell)
   {
      if(StateDue("WAITING_FOR_BREAKOUT"))State("WAITING_FOR_BREAKOUT",StringFormat("bid=%.5f ask=%.5f buy=%.5f sell=%.5f",q.bid,q.ask,buyLine,sellLine));
      return;
   }
   if(SymbolBusy()) { State("SYMBOL_HAS_POSITION_OR_ORDER");return; }
   if(!MQLInfoInteger(MQL_TRADE_ALLOWED) || !TerminalInfoInteger(TERMINAL_TRADE_ALLOWED) ||
      !AccountInfoInteger(ACCOUNT_TRADE_ALLOWED) || !AccountInfoInteger(ACCOUNT_TRADE_EXPERT))
   { State("ALGO_TRADING_NOT_ALLOWED");return; }
   OpenTrade(buy,q);
}

// 6. Lifecycle. Chart timeframe does not gate touch entries.
int OnInit()
{
   if(!ValidTime(Range_Start_Hour,Range_Start_Minute) || !ValidTime(Range_End_Hour,Range_End_Minute) ||
      !ValidTime(Trade_Close_Hour,Trade_Close_Minute) ||
      Minutes(Range_Start_Hour,Range_Start_Minute)>=Minutes(Range_End_Hour,Range_End_Minute) ||
      Minutes(Range_End_Hour,Range_End_Minute)>=Minutes(Trade_Close_Hour,Trade_Close_Minute))return INIT_PARAMETERS_INCORRECT;
   if(Use_Entry_Time_Filter && (!ValidTime(Entry_Start_Hour,Entry_Start_Minute) ||
      !ValidTime(Entry_End_Hour,Entry_End_Minute) ||
      Minutes(Entry_Start_Hour,Entry_Start_Minute)>=Minutes(Entry_End_Hour,Entry_End_Minute) ||
      Minutes(Entry_End_Hour,Entry_End_Minute)>Minutes(Trade_Close_Hour,Trade_Close_Minute) ||
      Minutes(Entry_End_Hour,Entry_End_Minute)<=Minutes(Range_End_Hour,Range_End_Minute)))return INIT_PARAMETERS_INCORRECT;
   if((Stop_Type==STOP_ATR && Stop_ATR_Mult<=0) ||
      (Stop_Type==STOP_PRICE_PERCENT && (Stop_Price_Percent<=0 || Stop_Price_Percent>=100)) ||
      (ReferenceATRNeeded() && Reference_ATR_Period<1) ||
      ATR_Buffer_Mult<0 || Buffer_ATR_Period<1 ||
      Risk_Percent<=0 || Risk_Percent>100 || Fixed_Lot<=0 || Retry_Seconds<1 ||
      Log_Repeat_Seconds<1 || Panel_Refresh_Seconds<1 || Max_Spread_Points<0 || Slippage_Points<0 || Magic_Number==0 ||
      (!Allow_Long && !Allow_Short) || TickSize()<=0)return INIT_PARAMETERS_INCORRECT;
   if(Use_Range_Filter && (Range_Filter_Measure==RANGE_ATR ?
      (Min_Range_ATR<0 || Max_Range_ATR<Min_Range_ATR) :
      (Min_Range_Percent<0 || Max_Range_Percent<Min_Range_Percent)))return INIT_PARAMETERS_INCORRECT;
   trade.SetExpertMagicNumber(Magic_Number);trade.SetDeviationInPoints(Slippage_Points);
   trade.SetAsyncMode(false);
   if(!trade.SetTypeFillingBySymbol(_Symbol))return INIT_FAILED;
   if(ReferenceATRNeeded())
   {
      stopHandle=iATR(_Symbol,Reference_ATR_Timeframe,Reference_ATR_Period);
      if(stopHandle==INVALID_HANDLE)return INIT_FAILED;
   }
   if(ATR_Buffer_Mult>0)
   {
      bufferHandle=iATR(_Symbol,Buffer_ATR_Timeframe,Buffer_ATR_Period);
      if(bufferHandle==INVALID_HANDLE) { if(stopHandle!=INVALID_HANDLE)IndicatorRelease(stopHandle);return INIT_FAILED; }
   }
   visuals=Draw_Range && (!MQLInfoInteger(MQL_TESTER) || MQLInfoInteger(MQL_VISUAL_MODE));
   prefix=StringFormat("ORB_V3_%s_%I64u_",_Symbol,Magic_Number);
   ResetDay();Log("INIT: direct broker clock; every-tick level entry; one successful entry/day; no automatic UTC/DST conversion.");
   Log(StringFormat("STOP mode=%s ATRmult=%.3f PricePct=%.3f%%",
      Stop_Type==STOP_ATR ? "ATR" : "PRICE_PERCENT",Stop_ATR_Mult,Stop_Price_Percent));
   Log(StringFormat("SIZE balance=%.2f risk=%.3f%% minLot=%.8f step=%.8f maxLot=%.8f",AccountInfoDouble(ACCOUNT_BALANCE),Risk_Percent,SymbolInfoDouble(_Symbol,SYMBOL_VOLUME_MIN),SymbolInfoDouble(_Symbol,SYMBOL_VOLUME_STEP),SymbolInfoDouble(_Symbol,SYMBOL_VOLUME_MAX)));
   return INIT_SUCCEEDED;
}
void OnDeinit(const int reason)
{
   if(stopHandle!=INVALID_HANDLE)IndicatorRelease(stopHandle);
   if(bufferHandle!=INVALID_HANDLE)IndicatorRelease(bufferHandle);
   if(visuals && prefix!="") { ObjectsDeleteAll(0,prefix);Comment(""); }
}
void OnTick()
{
   ResetDay();
   // Exits ALWAYS run before entry fast paths, including after one trade/day.
   CheckExits();
   if(unresolvedRequest)ReconcileRequest();
   datetime now=TimeCurrent();
   if(now>=closeTime) { State("DAILY_CLOSE_TIME");UpdatePanel();return; }
   // No history copies, indicator requests or chart work in the hot entry path.
   if(!ready && !PrepareRange()) { UpdatePanel();return; }
   if(traded) { State("ALREADY_TRADED_TODAY");UpdatePanel();return; }
   if(!rangePass) { State("RANGE_FILTER_REJECTED");UpdatePanel();return; }
   if(now<entryStart)
   {
      if(StateDue("BEFORE_ENTRY_WINDOW"))State("BEFORE_ENTRY_WINDOW",TimeToString(entryStart,TIME_MINUTES));
      UpdatePanel();return;
   }
   if(now>=entryEnd) { State("ENTRY_WINDOW_CLOSED");UpdatePanel();return; }
   CheckEntries(); // same executable Bid/Ask trigger, evaluated every eligible tick
   UpdatePanel();
}
void OnTradeTransaction(const MqlTradeTransaction &trans,const MqlTradeRequest &request,const MqlTradeResult &result)
{
   if(trans.symbol!=_Symbol)return;
   if(trans.type==TRADE_TRANSACTION_DEAL_ADD)
   {
      historyReady=RestoreTrades();
      RefreshOverduePosition();
   }
   // Order events bypass the polling throttle for prompt reconciliation.
   lastReconcile=0;
}
