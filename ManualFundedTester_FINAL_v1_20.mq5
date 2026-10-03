//+------------------------------------------------------------------+
//|                                      ManualFundedTester.mq5      |
//| Manual rule-based backtesting panel for MT5 Strategy Tester      |
//| Version 1.20                                                     |
//+------------------------------------------------------------------+
#property strict
#property version   "1.20"
#property description "Manual trading dashboard for MT5 Strategy Tester visual mode."
#property description "Risk sizing, tester-safe SL/TP adjustment, direct price keypad, RR, BE, partials and funded challenge stats."

#include <Trade/Trade.mqh>

CTrade trade;

enum ENUM_SIZE_MODE
  {
   SIZE_RISK_PERCENT = 0,
   SIZE_FIXED_LOT    = 1
  };

input group "=== Trading / Sizing ==="
input ulong          InpMagic                  = 26092701;
input ENUM_SIZE_MODE InpSizeMode               = SIZE_RISK_PERCENT;
input double         InpRiskPercent            = 0.50;
input bool           InpRiskUsesEquity         = true;
input double         InpFixedLot               = 0.10;
input double         InpDefaultRR              = 1.50;
input int            InpDefaultSLPoints        = 300;
input int            InpDeviationPoints        = 30;
input bool           InpAllowNewTradeWithOpen  = false;

input group "=== Management ==="
input double         InpPartial1Percent        = 25.0;
input double         InpPartial2Percent        = 50.0;
input double         InpPartial3Percent        = 75.0;
input int            InpBreakEvenOffsetPoints  = 0;
input int            InpAdjustStepPoints       = 25;
input int            InpSwingLookbackBars      = 5;

input group "=== Funded Challenge Simulation ==="
input double         InpProfitTargetPercent    = 10.0;
input double         InpMaxDailyLossPercent    = 5.0;
input double         InpMaxTotalLossPercent    = 10.0;
input bool           InpBlockEntriesAfterFail  = true;
input bool           InpBlockEntriesAfterPass  = false;

input group "=== Multi-Timeframe Context ==="
input bool            InpShowMTFContext         = true;
input ENUM_TIMEFRAMES InpContextTF1             = PERIOD_H1;
input ENUM_TIMEFRAMES InpContextTF2             = PERIOD_D1;
input int             InpContextEMAPeriod       = 20;

input group "=== Dashboard ==="
input ENUM_BASE_CORNER InpPanelCorner            = CORNER_LEFT_UPPER;
input int              InpPanelX                 = 12;
input int              InpPanelY                 = 22;
input int              InpTimerSeconds           = 1;

string PFX = "MFT_";

string OBJ_BG, OBJ_TITLE, OBJ_STATUS, OBJ_ACCOUNT, OBJ_CHALLENGE, OBJ_POSITION;
string OBJ_PLAN, OBJ_PRICE_INPUT, OBJ_CONTEXT1, OBJ_CONTEXT2, OBJ_MSG;
string BTN_PLAN_BUY, BTN_BUY, BTN_PLAN_SELL, BTN_SELL;
string BTN_CLOSE, BTN_BE, BTN_P25, BTN_P50, BTN_P75;
string BTN_MODE, BTN_RISK_MINUS, BTN_RISK_PLUS, BTN_RR_MINUS, BTN_RR_PLUS;
string BTN_SYNC_TP, BTN_CLEAR;
string BTN_SL_MINUS, BTN_SL_PLUS, BTN_TP_MINUS, BTN_TP_PLUS, BTN_STEP;
string BTN_LB_MINUS, BTN_SL_SWING, BTN_LB_PLUS;
string BTN_KEY0, BTN_KEY1, BTN_KEY2, BTN_KEY3, BTN_KEY4, BTN_KEY5, BTN_KEY6, BTN_KEY7, BTN_KEY8, BTN_KEY9;
string BTN_KEY_DOT, BTN_KEY_BKSP, BTN_INPUT_CLEAR, BTN_SET_SL_PRICE, BTN_SET_TP_PRICE, BTN_USE_BID, BTN_USE_ASK;
string LINE_SL, LINE_TP;

ENUM_SIZE_MODE g_size_mode;
double g_risk_pct;
double g_fixed_lot;
double g_rr;
int    g_adjust_step_points;
int    g_swing_lookback;
string g_price_input = "";

int    g_plan_dir = 0;
double g_plan_sl  = 0.0;
double g_plan_tp  = 0.0;
double g_last_sl_line = 0.0;
double g_last_tp_line = 0.0;

double g_initial_balance = 0.0;
double g_day_start_equity = 0.0;
int    g_day_key = -1;
bool   g_challenge_failed = false;
bool   g_challenge_passed = false;

double g_trade_initial_risk_cash = 0.0;
ulong  g_last_managed_ticket = 0;

int h_ema_tf1 = INVALID_HANDLE;
int h_ema_tf2 = INVALID_HANDLE;

string g_message = "Ready";
color  g_message_color = clrSilver;

double NPrice(double p)
  {
   int digits=(int)SymbolInfoInteger(_Symbol,SYMBOL_DIGITS);
   return NormalizeDouble(p,digits);
  }

double NVolume(double v)
  {
   double vmin=SymbolInfoDouble(_Symbol,SYMBOL_VOLUME_MIN);
   double vmax=SymbolInfoDouble(_Symbol,SYMBOL_VOLUME_MAX);
   double step=SymbolInfoDouble(_Symbol,SYMBOL_VOLUME_STEP);
   if(step<=0.0) return 0.0;

   v=MathMin(v,vmax);
   double n=MathFloor((v+1e-12)/step)*step;

   int vd=0;
   double s=step;
   while(vd<8 && MathAbs(s-MathRound(s))>1e-9)
     {
      s*=10.0;
      vd++;
     }
   n=NormalizeDouble(n,vd);
   if(n<vmin-1e-12) return 0.0;
   return n;
  }

string TFName(ENUM_TIMEFRAMES tf)
  {
   string s=EnumToString(tf);
   StringReplace(s,"PERIOD_","");
   return s;
  }

string FmtPrice(double p)
  {
   if(p<=0) return "-";
   int digits=(int)SymbolInfoInteger(_Symbol,SYMBOL_DIGITS);
   return DoubleToString(p,digits);
  }

string FmtPct(double p)
  {
   return DoubleToString(p,2)+"%";
  }

void SetMessage(string text,color c=clrSilver)
  {
   g_message=text;
   g_message_color=c;
  }

int DateKey(datetime t)
  {
   MqlDateTime d;
   TimeToStruct(t,d);
   return d.year*10000+d.mon*100+d.day;
  }

datetime StartOfDay(datetime t)
  {
   MqlDateTime d;
   TimeToStruct(t,d);
   d.hour=0; d.min=0; d.sec=0;
   return StructToTime(d);
  }

bool GetManagedPosition(ulong &ticket,long &ptype,double &volume,double &open_price,double &sl,double &tp)
  {
   ticket=0; ptype=-1; volume=0; open_price=0; sl=0; tp=0;

   for(int i=PositionsTotal()-1;i>=0;i--)
     {
      ulong tk=PositionGetTicket(i);
      if(tk==0) continue;
      if(!PositionSelectByTicket(tk)) continue;

      if(PositionGetString(POSITION_SYMBOL)!=_Symbol) continue;
      if((ulong)PositionGetInteger(POSITION_MAGIC)!=InpMagic) continue;

      ticket=tk;
      ptype=PositionGetInteger(POSITION_TYPE);
      volume=PositionGetDouble(POSITION_VOLUME);
      open_price=PositionGetDouble(POSITION_PRICE_OPEN);
      sl=PositionGetDouble(POSITION_SL);
      tp=PositionGetDouble(POSITION_TP);
      return true;
     }
   return false;
  }

bool HasManagedPosition()
  {
   ulong t; long ty; double v,o,s,p;
   return GetManagedPosition(t,ty,v,o,s,p);
  }

double FloatingPL()
  {
   double total=0.0;
   for(int i=PositionsTotal()-1;i>=0;i--)
     {
      ulong tk=PositionGetTicket(i);
      if(tk==0 || !PositionSelectByTicket(tk)) continue;
      if(PositionGetString(POSITION_SYMBOL)!=_Symbol) continue;
      if((ulong)PositionGetInteger(POSITION_MAGIC)!=InpMagic) continue;
      total+=PositionGetDouble(POSITION_PROFIT)+PositionGetDouble(POSITION_SWAP);
     }
   return total;
  }

double RiskBaseMoney()
  {
   return InpRiskUsesEquity ? AccountInfoDouble(ACCOUNT_EQUITY)
                            : AccountInfoDouble(ACCOUNT_BALANCE);
  }

double CalcRiskVolume(int dir,double entry,double sl)
  {
   if(g_size_mode==SIZE_FIXED_LOT)
      return NVolume(g_fixed_lot);

   if(sl<=0 || entry<=0 || MathAbs(entry-sl)<_Point*0.5)
      return 0.0;

   double risk_cash=RiskBaseMoney()*(g_risk_pct/100.0);
   if(risk_cash<=0) return 0.0;

   ENUM_ORDER_TYPE type=(dir>0 ? ORDER_TYPE_BUY : ORDER_TYPE_SELL);
   double profit_one_lot=0.0;

   if(!OrderCalcProfit(type,_Symbol,1.0,entry,sl,profit_one_lot))
      return 0.0;

   double loss_per_lot=MathAbs(profit_one_lot);
   if(loss_per_lot<=0.0) return 0.0;

   return NVolume(risk_cash/loss_per_lot);
  }

double CalcCashRiskForVolume(int dir,double volume,double entry,double sl)
  {
   if(volume<=0 || entry<=0 || sl<=0) return 0.0;
   ENUM_ORDER_TYPE type=(dir>0 ? ORDER_TYPE_BUY : ORDER_TYPE_SELL);
   double p=0.0;
   if(!OrderCalcProfit(type,_Symbol,volume,entry,sl,p))
      return 0.0;
   return MathAbs(p);
  }

double CurrentPlanEntry()
  {
   MqlTick tick;
   if(!SymbolInfoTick(_Symbol,tick)) return 0.0;
   if(g_plan_dir>0) return tick.ask;
   if(g_plan_dir<0) return tick.bid;
   return (tick.bid+tick.ask)/2.0;
  }

double PlannedRR()
  {
   double e=CurrentPlanEntry();
   if(e<=0 || g_plan_sl<=0 || g_plan_tp<=0 || g_plan_dir==0) return 0.0;

   double risk=MathAbs(e-g_plan_sl);
   if(risk<_Point*0.5) return 0.0;
   double reward=MathAbs(g_plan_tp-e);
   return reward/risk;
  }

//-------------------- TESTER-SAFE LINE ADJUSTMENT -------------------//
// MT5 Strategy Tester does not generate normal mouse/object events.
// Buttons are therefore used to move the visible SL/TP lines reliably.
void NudgeLine(string name,int direction)
  {
   if(ObjectFind(0,name)<0)
     {
      SetMessage("Create a BUY/SELL plan first",clrOrange);
      return;
     }

   int step=MathMax(1,g_adjust_step_points);
   double old_price=ObjectGetDouble(0,name,OBJPROP_PRICE);
   double new_price=NPrice(old_price + direction*step*_Point);
   ObjectSetDouble(0,name,OBJPROP_PRICE,new_price);
   ChartRedraw();

   string which=(name==LINE_SL ? "SL" : "TP");
   SetMessage(which+" moved to "+FmtPrice(new_price)+" (step "+IntegerToString(step)+" pts)",clrDeepSkyBlue);
  }

void CycleAdjustStep()
  {
   int steps[10]={1,5,10,25,50,100,250,500,1000,2500};
   int next=steps[0];
   bool found=false;

   for(int i=0;i<ArraySize(steps);i++)
     {
      if(g_adjust_step_points<steps[i])
        {
         next=steps[i];
         found=true;
         break;
        }
     }

   if(!found) next=steps[0];
   g_adjust_step_points=next;
   SetMessage("Adjustment step = "+IntegerToString(g_adjust_step_points)+" points",clrDeepSkyBlue);
  }

void SetSLToRecentSwing()
  {
   if(g_plan_dir==0)
     {
      SetMessage("Create a BUY/SELL plan first",clrOrange);
      return;
     }

   int bars=MathMax(1,g_swing_lookback);
   MqlRates r[];
   ArraySetAsSeries(r,true);
   int copied=CopyRates(_Symbol,_Period,1,bars,r);
   if(copied<=0)
     {
      SetMessage("Not enough bars for swing SL",clrTomato);
      return;
     }

   double level=(g_plan_dir>0 ? r[0].low : r[0].high);
   for(int i=1;i<copied;i++)
     {
      if(g_plan_dir>0) level=MathMin(level,r[i].low);
      else             level=MathMax(level,r[i].high);
     }

   level=NPrice(level);
   if(ObjectFind(0,LINE_SL)<0)
      CreateOrMoveLine(LINE_SL,level,clrTomato,"STOP LOSS");
   else
      ObjectSetDouble(0,LINE_SL,OBJPROP_PRICE,level);

   ChartRedraw();
   SetMessage("SL set to "+IntegerToString(copied)+"-bar "+(g_plan_dir>0?"low":"high")+" = "+FmtPrice(level),clrDeepSkyBlue);
  }


//--------------------- DIRECT PRICE KEYPAD --------------------------//
// Strategy Tester does not reliably support typing into OBJ_EDIT fields.
// This on-chart numeric keypad gives deterministic tester-safe price entry.
void PriceInputAppend(string token)
  {
   if(StringLen(g_price_input)>=18)
     {
      SetMessage("Price input is already at maximum length",clrOrange);
      return;
     }

   if(token==".")
     {
      if(StringFind(g_price_input,".")>=0) return;
      if(StringLen(g_price_input)==0) g_price_input="0";
     }

   g_price_input+=token;
   SetMessage("Price input = "+g_price_input,clrDeepSkyBlue);
  }

void PriceInputBackspace()
  {
   int n=StringLen(g_price_input);
   if(n<=0) return;
   g_price_input=StringSubstr(g_price_input,0,n-1);
   SetMessage("Price input = "+(StringLen(g_price_input)>0 ? g_price_input : "empty"),clrDeepSkyBlue);
  }

void PriceInputClear()
  {
   g_price_input="";
   SetMessage("Price input cleared",clrSilver);
  }

void PriceInputUseMarket(bool use_ask)
  {
   MqlTick tick;
   if(!SymbolInfoTick(_Symbol,tick))
     {
      SetMessage("No market tick available",clrTomato);
      return;
     }

   double p=(use_ask ? tick.ask : tick.bid);
   g_price_input=FmtPrice(p);
   SetMessage((use_ask ? "ASK" : "BID")+" copied to price input: "+g_price_input,clrDeepSkyBlue);
  }

bool ParsePriceInput(double &price)
  {
   price=0.0;
   if(StringLen(g_price_input)==0)
     {
      SetMessage("Enter a price with the keypad first",clrOrange);
      return false;
     }

   price=StringToDouble(g_price_input);
   if(price<=0.0)
     {
      SetMessage("Invalid price: "+g_price_input,clrTomato);
      return false;
     }

   price=NPrice(price);
   return true;
  }

void SetLineFromPriceInput(bool set_sl)
  {
   if(g_plan_dir==0 && !HasManagedPosition())
     {
      SetMessage("Create a BUY/SELL plan first",clrOrange);
      return;
     }

   double price=0.0;
   if(!ParsePriceInput(price)) return;

   string obj=(set_sl ? LINE_SL : LINE_TP);
   color c=(set_sl ? clrTomato : clrLimeGreen);
   string desc=(set_sl ? "STOP LOSS" : "TAKE PROFIT");

   if(ObjectFind(0,obj)<0)
      CreateOrMoveLine(obj,price,c,desc);
   else
      ObjectSetDouble(0,obj,OBJPROP_PRICE,price);

   if(set_sl) g_plan_sl=price;
   else       g_plan_tp=price;

   ChartRedraw();
   SetMessage((set_sl ? "SL" : "TP")+" set directly to "+FmtPrice(price),clrDeepSkyBlue);
  }

void UpdateDayState()
  {
   datetime now=TimeCurrent();
   int key=DateKey(now);
   if(g_day_key!=key)
     {
      g_day_key=key;
      g_day_start_equity=AccountInfoDouble(ACCOUNT_EQUITY);
     }
  }

int TodayEntryCount()
  {
   datetime from=StartOfDay(TimeCurrent());
   if(!HistorySelect(from,TimeCurrent())) return 0;

   int count=0;
   int n=HistoryDealsTotal();
   for(int i=0;i<n;i++)
     {
      ulong deal=HistoryDealGetTicket(i);
      if(deal==0) continue;
      if(HistoryDealGetString(deal,DEAL_SYMBOL)!=_Symbol) continue;
      if((ulong)HistoryDealGetInteger(deal,DEAL_MAGIC)!=InpMagic) continue;

      long entry=HistoryDealGetInteger(deal,DEAL_ENTRY);
      long type =HistoryDealGetInteger(deal,DEAL_TYPE);
      if(entry==DEAL_ENTRY_IN && (type==DEAL_TYPE_BUY || type==DEAL_TYPE_SELL))
         count++;
     }
   return count;
  }

void EvaluateChallenge()
  {
   double eq=AccountInfoDouble(ACCOUNT_EQUITY);
   double profit_pct=(g_initial_balance>0 ? (eq-g_initial_balance)/g_initial_balance*100.0 : 0.0);
   double daily_loss_pct=(g_initial_balance>0 ? MathMax(0.0,(g_day_start_equity-eq)/g_initial_balance*100.0) : 0.0);
   double total_loss_pct=(g_initial_balance>0 ? MathMax(0.0,(g_initial_balance-eq)/g_initial_balance*100.0) : 0.0);

   if(daily_loss_pct>=InpMaxDailyLossPercent-1e-9 ||
      total_loss_pct>=InpMaxTotalLossPercent-1e-9)
      g_challenge_failed=true;

   if(profit_pct>=InpProfitTargetPercent-1e-9)
      g_challenge_passed=true;
  }

bool NewEntriesBlocked()
  {
   if(g_challenge_failed && InpBlockEntriesAfterFail) return true;
   if(g_challenge_passed && InpBlockEntriesAfterPass) return true;
   return false;
  }

bool CreateRect(string name,int x,int y,int w,int h,color bg,color border)
  {
   if(ObjectFind(0,name)>=0) return true;
   if(!ObjectCreate(0,name,OBJ_RECTANGLE_LABEL,0,0,0)) return false;
   ObjectSetInteger(0,name,OBJPROP_CORNER,InpPanelCorner);
   ObjectSetInteger(0,name,OBJPROP_XDISTANCE,x);
   ObjectSetInteger(0,name,OBJPROP_YDISTANCE,y);
   ObjectSetInteger(0,name,OBJPROP_XSIZE,w);
   ObjectSetInteger(0,name,OBJPROP_YSIZE,h);
   ObjectSetInteger(0,name,OBJPROP_BGCOLOR,bg);
   ObjectSetInteger(0,name,OBJPROP_BORDER_COLOR,border);
   ObjectSetInteger(0,name,OBJPROP_BORDER_TYPE,BORDER_FLAT);
   ObjectSetInteger(0,name,OBJPROP_BACK,false);
   ObjectSetInteger(0,name,OBJPROP_SELECTABLE,false);
   ObjectSetInteger(0,name,OBJPROP_HIDDEN,true);
   ObjectSetInteger(0,name,OBJPROP_ZORDER,0);
   return true;
  }

bool CreateLabel(string name,string text,int x,int y,int font_size,color c)
  {
   if(ObjectFind(0,name)<0)
     {
      if(!ObjectCreate(0,name,OBJ_LABEL,0,0,0)) return false;
      ObjectSetInteger(0,name,OBJPROP_CORNER,InpPanelCorner);
      ObjectSetInteger(0,name,OBJPROP_XDISTANCE,x);
      ObjectSetInteger(0,name,OBJPROP_YDISTANCE,y);
      ObjectSetInteger(0,name,OBJPROP_ANCHOR,ANCHOR_LEFT_UPPER);
      ObjectSetInteger(0,name,OBJPROP_SELECTABLE,false);
      ObjectSetInteger(0,name,OBJPROP_HIDDEN,true);
      ObjectSetString(0,name,OBJPROP_FONT,"Segoe UI");
     }
   ObjectSetInteger(0,name,OBJPROP_FONTSIZE,font_size);
   ObjectSetInteger(0,name,OBJPROP_COLOR,c);
   ObjectSetString(0,name,OBJPROP_TEXT,text);
   return true;
  }

bool CreateButton(string name,string text,int x,int y,int w,int h,color bg,color fg)
  {
   if(ObjectFind(0,name)<0)
     {
      if(!ObjectCreate(0,name,OBJ_BUTTON,0,0,0)) return false;
      ObjectSetInteger(0,name,OBJPROP_CORNER,InpPanelCorner);
      ObjectSetInteger(0,name,OBJPROP_XDISTANCE,x);
      ObjectSetInteger(0,name,OBJPROP_YDISTANCE,y);
      ObjectSetInteger(0,name,OBJPROP_XSIZE,w);
      ObjectSetInteger(0,name,OBJPROP_YSIZE,h);
      ObjectSetInteger(0,name,OBJPROP_FONTSIZE,9);
      ObjectSetString(0,name,OBJPROP_FONT,"Segoe UI");
      ObjectSetInteger(0,name,OBJPROP_BORDER_COLOR,clrDimGray);
      ObjectSetInteger(0,name,OBJPROP_SELECTABLE,false);
      ObjectSetInteger(0,name,OBJPROP_HIDDEN,true);
      ObjectSetInteger(0,name,OBJPROP_ZORDER,5);
      ObjectSetInteger(0,name,OBJPROP_STATE,false);
     }
   ObjectSetInteger(0,name,OBJPROP_BGCOLOR,bg);
   ObjectSetInteger(0,name,OBJPROP_COLOR,fg);
   ObjectSetString(0,name,OBJPROP_TEXT,text);
   return true;
  }

void SetLabelText(string name,string text,color c=clrWhite)
  {
   if(ObjectFind(0,name)>=0)
     {
      ObjectSetString(0,name,OBJPROP_TEXT,text);
      ObjectSetInteger(0,name,OBJPROP_COLOR,c);
     }
  }

bool ButtonPressed(string name)
  {
   if(ObjectFind(0,name)<0) return false;
   bool state=(bool)ObjectGetInteger(0,name,OBJPROP_STATE);
   if(!state) return false;
   ObjectSetInteger(0,name,OBJPROP_STATE,false);
   ChartRedraw();
   return true;
  }

void CreateOrMoveLine(string name,double price,color c,string description)
  {
   price=NPrice(price);
   if(ObjectFind(0,name)<0)
     {
      ObjectCreate(0,name,OBJ_HLINE,0,0,price);
      ObjectSetInteger(0,name,OBJPROP_COLOR,c);
      ObjectSetInteger(0,name,OBJPROP_WIDTH,2);
      ObjectSetInteger(0,name,OBJPROP_STYLE,STYLE_SOLID);
      ObjectSetInteger(0,name,OBJPROP_SELECTABLE,true);
      ObjectSetInteger(0,name,OBJPROP_SELECTED,false);
      ObjectSetInteger(0,name,OBJPROP_HIDDEN,false);
      ObjectSetInteger(0,name,OBJPROP_BACK,false);
      ObjectSetInteger(0,name,OBJPROP_ZORDER,3);
      ObjectSetString(0,name,OBJPROP_TOOLTIP,description+" — use panel controls in Strategy Tester");
     }
   ObjectSetDouble(0,name,OBJPROP_PRICE,price);
   ObjectSetString(0,name,OBJPROP_TEXT,description);
  }

void DeleteLines()
  {
   ObjectDelete(0,LINE_SL);
   ObjectDelete(0,LINE_TP);
   g_plan_sl=0.0;
   g_plan_tp=0.0;
   g_last_sl_line=0.0;
   g_last_tp_line=0.0;
   g_plan_dir=0;
  }

void DeletePanel()
  {
   int total=ObjectsTotal(0,-1,-1);
   for(int i=total-1;i>=0;i--)
     {
      string n=ObjectName(0,i,-1,-1);
      if(StringFind(n,PFX)==0)
         ObjectDelete(0,n);
     }
  }

string MTFInfo(ENUM_TIMEFRAMES tf,int handle)
  {
   MqlRates r[];
   ArraySetAsSeries(r,true);
   if(CopyRates(_Symbol,tf,0,2,r)<2)
      return TFName(tf)+": loading...";

   double ema[];
   ArraySetAsSeries(ema,true);
   double e=0.0;
   if(handle!=INVALID_HANDLE && CopyBuffer(handle,0,0,1,ema)==1)
      e=ema[0];

   string trend="FLAT";
   if(e>0.0)
     {
      if(r[0].close>e) trend="ABOVE EMA"+IntegerToString(InpContextEMAPeriod);
      else if(r[0].close<e) trend="BELOW EMA"+IntegerToString(InpContextEMAPeriod);
     }

   return TFName(tf)+"  O:"+FmtPrice(r[0].open)+
          " H:"+FmtPrice(r[0].high)+
          " L:"+FmtPrice(r[0].low)+
          " C:"+FmtPrice(r[0].close)+
          " | "+trend;
  }

void SetPlan(int dir)
  {
   MqlTick tick;
   if(!SymbolInfoTick(_Symbol,tick))
     {
      SetMessage("No market tick available",clrTomato);
      return;
     }

   g_plan_dir=dir;
   double entry=(dir>0 ? tick.ask : tick.bid);
   double dist=MathMax((double)InpDefaultSLPoints,1.0)*_Point;

   if(dir>0)
     {
      g_plan_sl=NPrice(entry-dist);
      g_plan_tp=NPrice(entry+dist*g_rr);
     }
   else
     {
      g_plan_sl=NPrice(entry+dist);
      g_plan_tp=NPrice(entry-dist*g_rr);
     }

   CreateOrMoveLine(LINE_SL,g_plan_sl,clrTomato,"STOP LOSS");
   CreateOrMoveLine(LINE_TP,g_plan_tp,clrLimeGreen,"TAKE PROFIT");

   g_last_sl_line=g_plan_sl;
   g_last_tp_line=g_plan_tp;

   SetMessage(dir>0 ? "BUY plan armed — adjust SL/TP with buttons, then BUY"
                    : "SELL plan armed — adjust SL/TP with buttons, then SELL",
              clrDeepSkyBlue);
  }

bool ValidateStopsForDirection(int dir,double entry,double sl,double tp,string &why)
  {
   if(sl<=0)
     {
      why="SL is required";
      return false;
     }

   if(dir>0 && sl>=entry)
     {
      why="BUY SL must be below entry";
      return false;
     }
   if(dir<0 && sl<=entry)
     {
      why="SELL SL must be above entry";
      return false;
     }

   if(tp>0)
     {
      if(dir>0 && tp<=entry)
        {
         why="BUY TP must be above entry";
         return false;
        }
      if(dir<0 && tp>=entry)
        {
         why="SELL TP must be below entry";
         return false;
        }
     }

   int stop_level=(int)SymbolInfoInteger(_Symbol,SYMBOL_TRADE_STOPS_LEVEL);
   double min_dist=stop_level*_Point;
   if(min_dist>0 && MathAbs(entry-sl)<min_dist)
     {
      why="SL is inside broker stop level";
      return false;
     }

   why="";
   return true;
  }

void ExecuteMarket(int dir)
  {
   if(NewEntriesBlocked())
     {
      SetMessage("Entry blocked by challenge status",clrTomato);
      return;
     }

   if(HasManagedPosition() && !InpAllowNewTradeWithOpen)
     {
      SetMessage("Managed position already open",clrOrange);
      return;
     }

   if(g_plan_dir!=dir || ObjectFind(0,LINE_SL)<0)
     {
      SetPlan(dir);
      string side_word=(dir>0 ? "BUY" : "SELL");
      SetMessage("Plan created. Adjust lines, then press "+side_word+" again.",clrOrange);
      return;
     }

   g_plan_sl=NPrice(ObjectGetDouble(0,LINE_SL,OBJPROP_PRICE));
   if(ObjectFind(0,LINE_TP)>=0)
      g_plan_tp=NPrice(ObjectGetDouble(0,LINE_TP,OBJPROP_PRICE));

   MqlTick tick;
   if(!SymbolInfoTick(_Symbol,tick))
     {
      SetMessage("No market tick",clrTomato);
      return;
     }

   double entry=(dir>0 ? tick.ask : tick.bid);
   string why;
   if(!ValidateStopsForDirection(dir,entry,g_plan_sl,g_plan_tp,why))
     {
      SetMessage(why,clrTomato);
      return;
     }

   double volume=CalcRiskVolume(dir,entry,g_plan_sl);
   if(volume<=0.0)
     {
      SetMessage("Calculated lot < minimum or sizing failed",clrTomato);
      return;
     }

   trade.SetExpertMagicNumber(InpMagic);
   trade.SetDeviationInPoints(InpDeviationPoints);
   trade.SetTypeFillingBySymbol(_Symbol);

   bool ok=false;
   if(dir>0)
      ok=trade.Buy(volume,_Symbol,0.0,g_plan_sl,g_plan_tp,"ManualFunded BUY");
   else
      ok=trade.Sell(volume,_Symbol,0.0,g_plan_sl,g_plan_tp,"ManualFunded SELL");

   if(!ok || (trade.ResultRetcode()!=TRADE_RETCODE_DONE &&
              trade.ResultRetcode()!=TRADE_RETCODE_DONE_PARTIAL &&
              trade.ResultRetcode()!=TRADE_RETCODE_PLACED))
     {
      SetMessage("Entry failed: "+trade.ResultRetcodeDescription(),clrTomato);
      return;
     }

   g_trade_initial_risk_cash=CalcCashRiskForVolume(dir,volume,entry,g_plan_sl);
   SetMessage((dir>0?"BUY ":"SELL ")+DoubleToString(volume,2)+" lots opened",clrLimeGreen);
  }

void SyncLinesToPosition()
  {
   ulong ticket; long ptype; double vol,open,sl,tp;
   if(!GetManagedPosition(ticket,ptype,vol,open,sl,tp)) return;

   g_last_managed_ticket=ticket;
   g_plan_dir=(ptype==POSITION_TYPE_BUY ? 1 : -1);

   if(sl>0.0)
     {
      g_plan_sl=sl;
      CreateOrMoveLine(LINE_SL,sl,clrTomato,"STOP LOSS");
      g_last_sl_line=sl;
     }

   if(tp>0.0)
     {
      g_plan_tp=tp;
      CreateOrMoveLine(LINE_TP,tp,clrLimeGreen,"TAKE PROFIT");
      g_last_tp_line=tp;
     }
  }

void ApplyDraggedLines()
  {
   if(ObjectFind(0,LINE_SL)<0 && ObjectFind(0,LINE_TP)<0) return;

   double sl=(ObjectFind(0,LINE_SL)>=0 ? NPrice(ObjectGetDouble(0,LINE_SL,OBJPROP_PRICE)) : 0.0);
   double tp=(ObjectFind(0,LINE_TP)>=0 ? NPrice(ObjectGetDouble(0,LINE_TP,OBJPROP_PRICE)) : 0.0);

   bool sl_changed=(sl>0 && MathAbs(sl-g_last_sl_line)>=_Point*0.5);
   bool tp_changed=(tp>0 && MathAbs(tp-g_last_tp_line)>=_Point*0.5);

   if(!sl_changed && !tp_changed) return;

   g_plan_sl=sl;
   g_plan_tp=tp;
   g_last_sl_line=sl;
   g_last_tp_line=tp;

   ulong ticket; long ptype; double vol,open,pos_sl,pos_tp;
   if(!GetManagedPosition(ticket,ptype,vol,open,pos_sl,pos_tp))
      return;

   int dir=(ptype==POSITION_TYPE_BUY ? 1 : -1);
   MqlTick tick;
   if(!SymbolInfoTick(_Symbol,tick)) return;
   double ref=(dir>0 ? tick.bid : tick.ask);

   string why;
   if(!ValidateStopsForDirection(dir,ref,sl,tp,why))
     {
      SetMessage("Line not applied: "+why,clrTomato);
      return;
     }

   if(!trade.PositionModify(ticket,sl,tp) ||
      (trade.ResultRetcode()!=TRADE_RETCODE_DONE &&
       trade.ResultRetcode()!=TRADE_RETCODE_NO_CHANGES))
     {
      SetMessage("Modify failed: "+trade.ResultRetcodeDescription(),clrTomato);
      return;
     }

   SetMessage("SL/TP updated",clrDeepSkyBlue);
  }

void SyncTPToRR()
  {
   ulong ticket; long ptype; double vol,open,sl,tp;
   bool in_pos=GetManagedPosition(ticket,ptype,vol,open,sl,tp);

   int dir=g_plan_dir;
   double entry=CurrentPlanEntry();
   double use_sl=g_plan_sl;

   if(in_pos)
     {
      dir=(ptype==POSITION_TYPE_BUY ? 1 : -1);
      entry=open;
      use_sl=(ObjectFind(0,LINE_SL)>=0 ? ObjectGetDouble(0,LINE_SL,OBJPROP_PRICE) : sl);
     }

   if(dir==0 || entry<=0 || use_sl<=0)
     {
      SetMessage("Create a BUY/SELL plan first",clrOrange);
      return;
     }

   double risk=MathAbs(entry-use_sl);
   if(risk<_Point)
     {
      SetMessage("SL too close to entry",clrTomato);
      return;
     }

   double new_tp=(dir>0 ? entry+risk*g_rr : entry-risk*g_rr);
   g_plan_tp=NPrice(new_tp);
   CreateOrMoveLine(LINE_TP,g_plan_tp,clrLimeGreen,"TAKE PROFIT");
   g_last_tp_line=g_plan_tp;

   if(in_pos)
     {
      double use_tp=g_plan_tp;
      if(!trade.PositionModify(ticket,NPrice(use_sl),use_tp))
         SetMessage("TP sync failed: "+trade.ResultRetcodeDescription(),clrTomato);
      else
         SetMessage("TP synced to "+DoubleToString(g_rr,2)+"R",clrDeepSkyBlue);
     }
   else
      SetMessage("Planned TP synced to "+DoubleToString(g_rr,2)+"R",clrDeepSkyBlue);
  }

void CloseManaged()
  {
   ulong ticket; long ptype; double vol,open,sl,tp;
   if(!GetManagedPosition(ticket,ptype,vol,open,sl,tp))
     {
      SetMessage("No managed position",clrOrange);
      return;
     }

   if(!trade.PositionClose(ticket,InpDeviationPoints))
     {
      SetMessage("Close failed: "+trade.ResultRetcodeDescription(),clrTomato);
      return;
     }

   SetMessage("Position closed",clrLimeGreen);
   DeleteLines();
   g_trade_initial_risk_cash=0.0;
  }

void MoveToBE()
  {
   ulong ticket; long ptype; double vol,open,sl,tp;
   if(!GetManagedPosition(ticket,ptype,vol,open,sl,tp))
     {
      SetMessage("No managed position",clrOrange);
      return;
     }

   MqlTick tick;
   if(!SymbolInfoTick(_Symbol,tick)) return;

   double new_sl=(ptype==POSITION_TYPE_BUY)
                 ? open+InpBreakEvenOffsetPoints*_Point
                 : open-InpBreakEvenOffsetPoints*_Point;

   if(ptype==POSITION_TYPE_BUY && new_sl>=tick.bid)
     {
      SetMessage("BE is above/current Bid — not valid yet",clrOrange);
      return;
     }
   if(ptype==POSITION_TYPE_SELL && new_sl<=tick.ask)
     {
      SetMessage("BE is below/current Ask — not valid yet",clrOrange);
      return;
     }

   new_sl=NPrice(new_sl);
   if(!trade.PositionModify(ticket,new_sl,tp))
     {
      SetMessage("BE failed: "+trade.ResultRetcodeDescription(),clrTomato);
      return;
     }

   g_plan_sl=new_sl;
   CreateOrMoveLine(LINE_SL,new_sl,clrTomato,"STOP LOSS");
   g_last_sl_line=new_sl;
   SetMessage("Stop moved to break-even",clrLimeGreen);
  }

void PartialClose(double percent)
  {
   ulong ticket; long ptype; double vol,open,sl,tp;
   if(!GetManagedPosition(ticket,ptype,vol,open,sl,tp))
     {
      SetMessage("No managed position",clrOrange);
      return;
     }

   double vmin=SymbolInfoDouble(_Symbol,SYMBOL_VOLUME_MIN);
   double close_vol=NVolume(vol*(percent/100.0));

   if(close_vol<=0)
     {
      SetMessage("Partial volume below symbol minimum",clrOrange);
      return;
     }

   double remain=vol-close_vol;
   if(remain>0 && remain<vmin-1e-12)
     {
      double adjusted=NVolume(vol-vmin);
      if(adjusted>0) close_vol=adjusted;
      else
        {
         SetMessage("Cannot partial without leaving minimum volume",clrOrange);
         return;
        }
     }

   bool ok=false;
   ENUM_ACCOUNT_MARGIN_MODE mm=(ENUM_ACCOUNT_MARGIN_MODE)AccountInfoInteger(ACCOUNT_MARGIN_MODE);

   if(mm==ACCOUNT_MARGIN_MODE_RETAIL_HEDGING)
      ok=trade.PositionClosePartial(ticket,close_vol,InpDeviationPoints);
   else
     {
      if(ptype==POSITION_TYPE_BUY)
         ok=trade.Sell(close_vol,_Symbol,0.0,0.0,0.0,"Manual partial close");
      else
         ok=trade.Buy(close_vol,_Symbol,0.0,0.0,0.0,"Manual partial close");
     }

   if(!ok)
     {
      SetMessage("Partial failed: "+trade.ResultRetcodeDescription(),clrTomato);
      return;
     }

   SetMessage("Partial close "+DoubleToString(percent,0)+"%",clrLimeGreen);
  }

void BuildDashboard()
  {
   int x=InpPanelX, y=InpPanelY;
   int w=390, h=795;

   OBJ_BG       =PFX+"BG";
   OBJ_TITLE    =PFX+"TITLE";
   OBJ_STATUS   =PFX+"STATUS";
   OBJ_ACCOUNT  =PFX+"ACCOUNT";
   OBJ_CHALLENGE=PFX+"CHALLENGE";
   OBJ_POSITION =PFX+"POSITION";
   OBJ_PLAN     =PFX+"PLAN";
   OBJ_PRICE_INPUT=PFX+"PRICE_INPUT";
   OBJ_CONTEXT1 =PFX+"CTX1";
   OBJ_CONTEXT2 =PFX+"CTX2";
   OBJ_MSG      =PFX+"MSG";

   BTN_PLAN_BUY =PFX+"BTN_PLAN_BUY";
   BTN_BUY      =PFX+"BTN_BUY";
   BTN_PLAN_SELL=PFX+"BTN_PLAN_SELL";
   BTN_SELL     =PFX+"BTN_SELL";
   BTN_CLOSE    =PFX+"BTN_CLOSE";
   BTN_BE       =PFX+"BTN_BE";
   BTN_P25      =PFX+"BTN_P25";
   BTN_P50      =PFX+"BTN_P50";
   BTN_P75      =PFX+"BTN_P75";
   BTN_MODE     =PFX+"BTN_MODE";
   BTN_RISK_MINUS=PFX+"BTN_RISK_MINUS";
   BTN_RISK_PLUS =PFX+"BTN_RISK_PLUS";
   BTN_RR_MINUS  =PFX+"BTN_RR_MINUS";
   BTN_RR_PLUS   =PFX+"BTN_RR_PLUS";
   BTN_SYNC_TP   =PFX+"BTN_SYNC_TP";
   BTN_CLEAR     =PFX+"BTN_CLEAR";
   BTN_SL_MINUS  =PFX+"BTN_SL_MINUS";
   BTN_SL_PLUS   =PFX+"BTN_SL_PLUS";
   BTN_TP_MINUS  =PFX+"BTN_TP_MINUS";
   BTN_TP_PLUS   =PFX+"BTN_TP_PLUS";
   BTN_STEP      =PFX+"BTN_STEP";
   BTN_LB_MINUS  =PFX+"BTN_LB_MINUS";
   BTN_SL_SWING  =PFX+"BTN_SL_SWING";
   BTN_LB_PLUS   =PFX+"BTN_LB_PLUS";
   BTN_KEY0      =PFX+"BTN_KEY0";
   BTN_KEY1      =PFX+"BTN_KEY1";
   BTN_KEY2      =PFX+"BTN_KEY2";
   BTN_KEY3      =PFX+"BTN_KEY3";
   BTN_KEY4      =PFX+"BTN_KEY4";
   BTN_KEY5      =PFX+"BTN_KEY5";
   BTN_KEY6      =PFX+"BTN_KEY6";
   BTN_KEY7      =PFX+"BTN_KEY7";
   BTN_KEY8      =PFX+"BTN_KEY8";
   BTN_KEY9      =PFX+"BTN_KEY9";
   BTN_KEY_DOT   =PFX+"BTN_KEY_DOT";
   BTN_KEY_BKSP  =PFX+"BTN_KEY_BKSP";
   BTN_INPUT_CLEAR=PFX+"BTN_INPUT_CLEAR";
   BTN_SET_SL_PRICE=PFX+"BTN_SET_SL_PRICE";
   BTN_SET_TP_PRICE=PFX+"BTN_SET_TP_PRICE";
   BTN_USE_BID   =PFX+"BTN_USE_BID";
   BTN_USE_ASK   =PFX+"BTN_USE_ASK";
   LINE_SL       =PFX+"LINE_SL";
   LINE_TP       =PFX+"LINE_TP";

   CreateRect(OBJ_BG,x,y,w,h,clrBlack,clrDimGray);
   CreateLabel(OBJ_TITLE,"MANUAL FUNDED TESTER",x+14,y+10,13,clrWhite);
   CreateLabel(OBJ_STATUS,"",x+14,y+36,10,clrLimeGreen);
   CreateLabel(OBJ_ACCOUNT,"",x+14,y+60,9,clrSilver);
   CreateLabel(OBJ_CHALLENGE,"",x+14,y+105,9,clrSilver);
   CreateLabel(OBJ_POSITION,"",x+14,y+167,9,clrSilver);
   CreateLabel(OBJ_PLAN,"",x+14,y+235,9,clrSilver);

   CreateButton(BTN_PLAN_BUY,"PLAN BUY", x+14,y+312,82,28,clrDarkSlateGray,clrWhite);
   CreateButton(BTN_BUY,     "BUY",      x+102,y+312,82,28,clrDarkGreen,clrWhite);
   CreateButton(BTN_PLAN_SELL,"PLAN SELL",x+198,y+312,82,28,clrDarkSlateGray,clrWhite);
   CreateButton(BTN_SELL,    "SELL",     x+286,y+312,82,28,clrMaroon,clrWhite);

   CreateButton(BTN_CLOSE,"CLOSE",x+14,y+350,68,27,clrFireBrick,clrWhite);
   CreateButton(BTN_BE,   "BE",   x+88,y+350,54,27,clrDarkSlateBlue,clrWhite);
   CreateButton(BTN_P25,  "25%",  x+148,y+350,54,27,clrDarkSlateGray,clrWhite);
   CreateButton(BTN_P50,  "50%",  x+208,y+350,54,27,clrDarkSlateGray,clrWhite);
   CreateButton(BTN_P75,  "75%",  x+268,y+350,54,27,clrDarkSlateGray,clrWhite);
   CreateButton(BTN_CLEAR,"CLEAR", x+328,y+350,40,27,clrDimGray,clrWhite);

   CreateButton(BTN_MODE,"MODE",x+14,y+390,84,26,clrDarkSlateGray,clrWhite);
   CreateButton(BTN_RISK_MINUS,"SIZE -",x+104,y+390,64,26,clrDarkSlateGray,clrWhite);
   CreateButton(BTN_RISK_PLUS, "SIZE +",x+174,y+390,64,26,clrDarkSlateGray,clrWhite);
   CreateButton(BTN_RR_MINUS,  "RR -",x+244,y+390,58,26,clrDarkSlateGray,clrWhite);
   CreateButton(BTN_RR_PLUS,   "RR +",x+308,y+390,60,26,clrDarkSlateGray,clrWhite);

   CreateButton(BTN_SYNC_TP,"SYNC TP TO RR",x+14,y+426,354,28,clrDarkSlateBlue,clrWhite);

   CreateButton(BTN_SL_MINUS,"SL -",x+14,y+466,54,26,clrFireBrick,clrWhite);
   CreateButton(BTN_SL_PLUS, "SL +",x+74,y+466,54,26,clrFireBrick,clrWhite);
   CreateButton(BTN_TP_MINUS,"TP -",x+134,y+466,54,26,clrDarkGreen,clrWhite);
   CreateButton(BTN_TP_PLUS, "TP +",x+194,y+466,54,26,clrDarkGreen,clrWhite);
   CreateButton(BTN_STEP,    "STEP",x+254,y+466,114,26,clrDarkSlateGray,clrWhite);

   CreateButton(BTN_LB_MINUS,"LB -",x+14,y+500,64,26,clrDarkSlateGray,clrWhite);
   CreateButton(BTN_SL_SWING,"SL SWING",x+84,y+500,214,26,clrDarkSlateBlue,clrWhite);
   CreateButton(BTN_LB_PLUS, "LB +",x+304,y+500,64,26,clrDarkSlateGray,clrWhite);

   CreateLabel(OBJ_PRICE_INPUT,"PRICE ENTRY: [empty]",x+14,y+536,9,clrGold);

   // Compact tester-safe numeric keypad: 7 8 9 4 5 6 / 1 2 3 0 . BKSP
   CreateButton(BTN_KEY7,"7",x+14,y+562,54,25,clrDarkSlateGray,clrWhite);
   CreateButton(BTN_KEY8,"8",x+74,y+562,54,25,clrDarkSlateGray,clrWhite);
   CreateButton(BTN_KEY9,"9",x+134,y+562,54,25,clrDarkSlateGray,clrWhite);
   CreateButton(BTN_KEY4,"4",x+194,y+562,54,25,clrDarkSlateGray,clrWhite);
   CreateButton(BTN_KEY5,"5",x+254,y+562,54,25,clrDarkSlateGray,clrWhite);
   CreateButton(BTN_KEY6,"6",x+314,y+562,54,25,clrDarkSlateGray,clrWhite);

   CreateButton(BTN_KEY1,"1",x+14,y+593,54,25,clrDarkSlateGray,clrWhite);
   CreateButton(BTN_KEY2,"2",x+74,y+593,54,25,clrDarkSlateGray,clrWhite);
   CreateButton(BTN_KEY3,"3",x+134,y+593,54,25,clrDarkSlateGray,clrWhite);
   CreateButton(BTN_KEY0,"0",x+194,y+593,54,25,clrDarkSlateGray,clrWhite);
   CreateButton(BTN_KEY_DOT,".",x+254,y+593,54,25,clrDarkSlateGray,clrWhite);
   CreateButton(BTN_KEY_BKSP,"BKSP",x+314,y+593,54,25,clrDimGray,clrWhite);

   CreateButton(BTN_INPUT_CLEAR,"CLR INPUT",x+14,y+624,82,26,clrDimGray,clrWhite);
   CreateButton(BTN_SET_SL_PRICE,"SET SL",x+102,y+624,70,26,clrFireBrick,clrWhite);
   CreateButton(BTN_SET_TP_PRICE,"SET TP",x+178,y+624,70,26,clrDarkGreen,clrWhite);
   CreateButton(BTN_USE_BID,"BID",x+254,y+624,54,26,clrDarkSlateBlue,clrWhite);
   CreateButton(BTN_USE_ASK,"ASK",x+314,y+624,54,26,clrDarkSlateBlue,clrWhite);

   CreateLabel(OBJ_CONTEXT1,"",x+14,y+664,8,clrLightSteelBlue);
   CreateLabel(OBJ_CONTEXT2,"",x+14,y+687,8,clrLightSteelBlue);
   CreateLabel(OBJ_MSG,"",x+14,y+724,9,clrSilver);

   ChartRedraw();
  }

void UpdateDashboard()
  {
   UpdateDayState();
   EvaluateChallenge();

   double bal=AccountInfoDouble(ACCOUNT_BALANCE);
   double eq =AccountInfoDouble(ACCOUNT_EQUITY);
   double float_pl=FloatingPL();

   double profit_pct=(g_initial_balance>0 ? (eq-g_initial_balance)/g_initial_balance*100.0 : 0.0);
   double daily_pl=eq-g_day_start_equity;
   double daily_loss_pct=(g_initial_balance>0 ? MathMax(0.0,-daily_pl/g_initial_balance*100.0) : 0.0);
   double total_loss_pct=(g_initial_balance>0 ? MathMax(0.0,(g_initial_balance-eq)/g_initial_balance*100.0) : 0.0);

   string challenge_status="ACTIVE";
   color status_color=clrLimeGreen;
   if(g_challenge_failed)
     {
      challenge_status="FAILED";
      status_color=clrTomato;
     }
   else if(g_challenge_passed)
     {
      challenge_status="PASSED";
      status_color=clrLimeGreen;
     }

   SetLabelText(OBJ_STATUS,
                _Symbol+" | "+TimeToString(TimeCurrent(),TIME_DATE|TIME_SECONDS)+" | "+challenge_status,
                status_color);

   SetLabelText(OBJ_ACCOUNT,
                "Balance: "+DoubleToString(bal,2)+
                "   Equity: "+DoubleToString(eq,2)+
                "   Floating: "+DoubleToString(float_pl,2)+
                "\nDay P/L: "+DoubleToString(daily_pl,2)+
                "   Trades today: "+IntegerToString(TodayEntryCount()),
                clrSilver);

   SetLabelText(OBJ_CHALLENGE,
                "Target: "+FmtPct(InpProfitTargetPercent)+
                "   Current: "+FmtPct(profit_pct)+
                "\nDaily loss: "+FmtPct(daily_loss_pct)+" / "+FmtPct(InpMaxDailyLossPercent)+
                "   Total loss: "+FmtPct(total_loss_pct)+" / "+FmtPct(InpMaxTotalLossPercent),
                clrSilver);

   ulong ticket; long ptype; double vol,open,sl,tp;
   if(GetManagedPosition(ticket,ptype,vol,open,sl,tp))
     {
      int dir=(ptype==POSITION_TYPE_BUY ? 1 : -1);
      double r=(g_trade_initial_risk_cash>0 ? float_pl/g_trade_initial_risk_cash : 0.0);
      SetLabelText(OBJ_POSITION,
                   "OPEN POSITION: "+(dir>0 ? "BUY " : "SELL ")+DoubleToString(vol,2)+
                   "   Entry: "+FmtPrice(open)+
                   "\nSL: "+FmtPrice(sl)+"   TP: "+FmtPrice(tp)+
                   "   Floating R: "+DoubleToString(r,2)+"R",
                   dir>0 ? clrPaleGreen : clrLightSalmon);
     }
   else
     {
      SetLabelText(OBJ_POSITION,"OPEN POSITION: none\nUse PLAN BUY/SELL, adjust SL/TP, then execute.",clrSilver);
     }

   string mode=(g_size_mode==SIZE_RISK_PERCENT
                ? "RISK "+DoubleToString(g_risk_pct,2)+"%"
                : "FIXED "+DoubleToString(g_fixed_lot,2)+" lot");

   string side=(g_plan_dir>0?"BUY":g_plan_dir<0?"SELL":"NONE");
   double preview=0.0;
   if(g_plan_dir!=0 && g_plan_sl>0)
      preview=CalcRiskVolume(g_plan_dir,CurrentPlanEntry(),g_plan_sl);

   SetLabelText(OBJ_PLAN,
                "PLAN: "+side+
                "   Mode: "+mode+
                "   RR setting: "+DoubleToString(g_rr,2)+
                "\nSL: "+FmtPrice(g_plan_sl)+
                "   TP: "+FmtPrice(g_plan_tp)+
                "   Live RR: "+DoubleToString(PlannedRR(),2)+
                "\nPreview volume: "+(preview>0?DoubleToString(preview,2):"-")+
                "   (adjust with SL/TP buttons below)",
                clrSilver);

   if(InpShowMTFContext)
     {
      SetLabelText(OBJ_CONTEXT1,"CTX1  "+MTFInfo(InpContextTF1,h_ema_tf1),clrLightSteelBlue);
      SetLabelText(OBJ_CONTEXT2,"CTX2  "+MTFInfo(InpContextTF2,h_ema_tf2),clrLightSteelBlue);
     }
   else
     {
      SetLabelText(OBJ_CONTEXT1,"",clrSilver);
      SetLabelText(OBJ_CONTEXT2,"",clrSilver);
     }

   SetLabelText(OBJ_PRICE_INPUT,"PRICE ENTRY: ["+(StringLen(g_price_input)>0 ? g_price_input : "empty")+"]",clrGold);
   SetLabelText(OBJ_MSG,"STATUS: "+g_message,g_message_color);

   string mode_btn=(g_size_mode==SIZE_RISK_PERCENT ? "% RISK" : "FIX LOT");
   ObjectSetString(0,BTN_MODE,OBJPROP_TEXT,mode_btn);
   ObjectSetString(0,BTN_STEP,OBJPROP_TEXT,"STEP "+IntegerToString(g_adjust_step_points)+" pts");
   ObjectSetString(0,BTN_SL_SWING,OBJPROP_TEXT,"SL = SWING "+IntegerToString(g_swing_lookback)+" bars");

   ChartRedraw();
  }

void PollUI()
  {
   if(ButtonPressed(BTN_PLAN_BUY))  SetPlan(1);
   if(ButtonPressed(BTN_BUY))       ExecuteMarket(1);
   if(ButtonPressed(BTN_PLAN_SELL)) SetPlan(-1);
   if(ButtonPressed(BTN_SELL))      ExecuteMarket(-1);

   if(ButtonPressed(BTN_CLOSE)) CloseManaged();
   if(ButtonPressed(BTN_BE))    MoveToBE();
   if(ButtonPressed(BTN_P25))   PartialClose(InpPartial1Percent);
   if(ButtonPressed(BTN_P50))   PartialClose(InpPartial2Percent);
   if(ButtonPressed(BTN_P75))   PartialClose(InpPartial3Percent);
   if(ButtonPressed(BTN_CLEAR))
     {
      if(HasManagedPosition())
         SetMessage("Cannot clear SL/TP while position is open",clrOrange);
      else
        {
         DeleteLines();
         SetMessage("Plan cleared",clrSilver);
        }
     }

   if(ButtonPressed(BTN_MODE))
     {
      g_size_mode=(g_size_mode==SIZE_RISK_PERCENT ? SIZE_FIXED_LOT : SIZE_RISK_PERCENT);
      SetMessage(g_size_mode==SIZE_RISK_PERCENT ? "Sizing mode: risk %" : "Sizing mode: fixed lot",clrDeepSkyBlue);
     }

   if(ButtonPressed(BTN_RISK_MINUS))
     {
      if(g_size_mode==SIZE_RISK_PERCENT)
         g_risk_pct=MathMax(0.05,g_risk_pct-0.05);
      else
        {
         double step=SymbolInfoDouble(_Symbol,SYMBOL_VOLUME_STEP);
         g_fixed_lot=MathMax(SymbolInfoDouble(_Symbol,SYMBOL_VOLUME_MIN),g_fixed_lot-step);
         g_fixed_lot=NVolume(g_fixed_lot);
        }
     }

   if(ButtonPressed(BTN_RISK_PLUS))
     {
      if(g_size_mode==SIZE_RISK_PERCENT)
         g_risk_pct=MathMin(10.0,g_risk_pct+0.05);
      else
        {
         double step=SymbolInfoDouble(_Symbol,SYMBOL_VOLUME_STEP);
         g_fixed_lot=NVolume(g_fixed_lot+step);
        }
     }

   if(ButtonPressed(BTN_RR_MINUS))
     {
      g_rr=MathMax(0.25,g_rr-0.25);
      SetMessage("RR setting: "+DoubleToString(g_rr,2),clrDeepSkyBlue);
     }

   if(ButtonPressed(BTN_RR_PLUS))
     {
      g_rr=MathMin(10.0,g_rr+0.25);
      SetMessage("RR setting: "+DoubleToString(g_rr,2),clrDeepSkyBlue);
     }

   if(ButtonPressed(BTN_SYNC_TP)) SyncTPToRR();

   if(ButtonPressed(BTN_SL_MINUS)) NudgeLine(LINE_SL,-1);
   if(ButtonPressed(BTN_SL_PLUS))  NudgeLine(LINE_SL, 1);
   if(ButtonPressed(BTN_TP_MINUS)) NudgeLine(LINE_TP,-1);
   if(ButtonPressed(BTN_TP_PLUS))  NudgeLine(LINE_TP, 1);
   if(ButtonPressed(BTN_STEP))     CycleAdjustStep();

   if(ButtonPressed(BTN_LB_MINUS))
     {
      g_swing_lookback=MathMax(1,g_swing_lookback-1);
      SetMessage("Swing lookback = "+IntegerToString(g_swing_lookback)+" bars",clrDeepSkyBlue);
     }
   if(ButtonPressed(BTN_LB_PLUS))
     {
      g_swing_lookback=MathMin(100,g_swing_lookback+1);
      SetMessage("Swing lookback = "+IntegerToString(g_swing_lookback)+" bars",clrDeepSkyBlue);
     }
   if(ButtonPressed(BTN_SL_SWING)) SetSLToRecentSwing();

   if(ButtonPressed(BTN_KEY0)) PriceInputAppend("0");
   if(ButtonPressed(BTN_KEY1)) PriceInputAppend("1");
   if(ButtonPressed(BTN_KEY2)) PriceInputAppend("2");
   if(ButtonPressed(BTN_KEY3)) PriceInputAppend("3");
   if(ButtonPressed(BTN_KEY4)) PriceInputAppend("4");
   if(ButtonPressed(BTN_KEY5)) PriceInputAppend("5");
   if(ButtonPressed(BTN_KEY6)) PriceInputAppend("6");
   if(ButtonPressed(BTN_KEY7)) PriceInputAppend("7");
   if(ButtonPressed(BTN_KEY8)) PriceInputAppend("8");
   if(ButtonPressed(BTN_KEY9)) PriceInputAppend("9");
   if(ButtonPressed(BTN_KEY_DOT)) PriceInputAppend(".");
   if(ButtonPressed(BTN_KEY_BKSP)) PriceInputBackspace();
   if(ButtonPressed(BTN_INPUT_CLEAR)) PriceInputClear();
   if(ButtonPressed(BTN_USE_BID)) PriceInputUseMarket(false);
   if(ButtonPressed(BTN_USE_ASK)) PriceInputUseMarket(true);
   if(ButtonPressed(BTN_SET_SL_PRICE)) SetLineFromPriceInput(true);
   if(ButtonPressed(BTN_SET_TP_PRICE)) SetLineFromPriceInput(false);

   ApplyDraggedLines();
  }

int OnInit()
  {
   trade.SetExpertMagicNumber(InpMagic);
   trade.SetDeviationInPoints(InpDeviationPoints);
   trade.SetTypeFillingBySymbol(_Symbol);

   g_size_mode=InpSizeMode;
   g_risk_pct=MathMax(0.05,InpRiskPercent);
   g_fixed_lot=MathMax(SymbolInfoDouble(_Symbol,SYMBOL_VOLUME_MIN),InpFixedLot);
   g_fixed_lot=NVolume(g_fixed_lot);
   g_rr=MathMax(0.25,InpDefaultRR);
   g_adjust_step_points=MathMax(1,InpAdjustStepPoints);
   g_swing_lookback=MathMax(1,InpSwingLookbackBars);

   g_initial_balance=AccountInfoDouble(ACCOUNT_BALANCE);
   g_day_start_equity=AccountInfoDouble(ACCOUNT_EQUITY);
   g_day_key=DateKey(TimeCurrent());

   TesterHideIndicators(false);

   if(InpShowMTFContext)
     {
      h_ema_tf1=iMA(_Symbol,InpContextTF1,InpContextEMAPeriod,0,MODE_EMA,PRICE_CLOSE);
      h_ema_tf2=iMA(_Symbol,InpContextTF2,InpContextEMAPeriod,0,MODE_EMA,PRICE_CLOSE);
     }

   BuildDashboard();
   SyncLinesToPosition();

   int seconds=MathMax(1,InpTimerSeconds);
   EventSetTimer(seconds);

   SetMessage("Ready — create a plan first",clrSilver);
   UpdateDashboard();
   return(INIT_SUCCEEDED);
  }

void OnDeinit(const int reason)
  {
   EventKillTimer();

   if(h_ema_tf1!=INVALID_HANDLE) IndicatorRelease(h_ema_tf1);
   if(h_ema_tf2!=INVALID_HANDLE) IndicatorRelease(h_ema_tf2);

   DeletePanel();
   ChartRedraw();
  }

void OnTick()
  {
   PollUI();

   ulong t; long ty; double v,o,s,p;
   if(GetManagedPosition(t,ty,v,o,s,p))
     {
      if(t!=g_last_managed_ticket)
        {
         g_last_managed_ticket=t;
         SyncLinesToPosition();

         int dir=(ty==POSITION_TYPE_BUY ? 1 : -1);
         if(s>0)
            g_trade_initial_risk_cash=CalcCashRiskForVolume(dir,v,o,s);
        }
     }
   else
     {
      g_last_managed_ticket=0;
     }

   UpdateDashboard();
  }

void OnTimer()
  {
   PollUI();
   UpdateDashboard();
  }

void OnChartEvent(const int id,const long &lparam,const double &dparam,const string &sparam)
  {
   // Intentionally unused: tester-safe UI uses polling instead of chart events.
  }
//+------------------------------------------------------------------+
