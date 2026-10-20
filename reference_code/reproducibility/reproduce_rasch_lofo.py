#!/usr/bin/env python3

"""Frozen mathematical helper; legacy dataset/CLI removed during export."""

from __future__ import annotations

import argparse, csv, json

from pathlib import Path

import numpy as np

from scipy.optimize import minimize

from scipy.stats import pearsonr, spearmanr

RIDGE=1/9

def expit(x):
    x=np.asarray(x,dtype=float); o=np.empty_like(x); p=x>=0; o[p]=1/(1+np.exp(-x[p])); z=np.exp(x[~p]); o[~p]=z/(1+z); return o

def fit_rasch(Y):
    ni,ns=Y.shape; sr=(Y.sum(0)+.5)/(ni+1); th0=np.log(sr/(1-sr)); ir=(Y.sum(1)+.5)/(ns+1); b0=-np.log(ir/(1-ir)); x0=np.r_[th0,b0]
    def fg(x):
        th=x[:ns]; b=x[ns:]; eta=th[None,:]-b[:,None]; p=expit(eta); nll=np.logaddexp(0,eta).sum()-(Y*eta).sum(); obj=nll+.5*RIDGE*(th@th+b@b); return float(obj),np.r_[(p-Y).sum(0)+RIDGE*th,(Y-p).sum(1)+RIDGE*b]
    r=minimize(lambda x:fg(x)[0],x0,jac=lambda x:fg(x)[1],method='L-BFGS-B',options={'maxiter':10000,'ftol':1e-15,'gtol':1e-10,'maxls':80}); th=r.x[:ns]; b=r.x[ns:]; sh=float(th.mean()); th-=sh; b-=sh; p=expit(th[None,:]-b[:,None]); thse=1/np.sqrt((p*(1-p)).sum(0)+RIDGE); bse=1/np.sqrt((p*(1-p)).sum(1)+RIDGE); eps=1e-15; ll=float(-np.mean(Y*np.log(np.clip(p,eps,1-eps))+(1-Y)*np.log(np.clip(1-p,eps,1-eps)))); mae=float(np.mean(np.abs(Y.mean(0)-p.mean(0)))*100); rel=float(1-np.mean(thse**2)/np.var(th,ddof=1)); return {'success':bool(r.success),'theta':th,'b':b,'p':p,'theta_se':thse,'b_se':bse,'logloss':ll,'score_mae_pp':mae,'person_reliability_approx':rel}
